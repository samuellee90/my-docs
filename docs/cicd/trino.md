# Trino - K8s CI/CD

## 배포 개요

Trino는 **공식 Helm Chart**를 사용하며, 설정 변경은 ConfigMap을 통해 관리합니다.
코드 빌드는 없고 **설정 파일(values.yaml, catalog)** 변경이 주 배포 단위입니다.

---

## Helm Chart 설치

```bash
helm repo add trino https://trinodb.github.io/charts
helm repo update

helm install trino trino/trino \
  --namespace data \
  --create-namespace \
  -f charts/trino/values.yaml
```

---

## values.yaml 핵심 설정

```yaml
# charts/trino/values.yaml

image:
  repository: trinodb/trino
  tag: "447"
  pullPolicy: IfNotPresent

server:
  workers: 3

  # Coordinator JVM 설정
  coordinatorExtraConfig: |
    query.max-memory=10GB
    query.max-memory-per-node=2GB
    query.max-total-memory-per-node=4GB

  # Worker JVM 설정
  workerExtraConfig: |
    query.max-memory-per-node=2GB

coordinator:
  jvm:
    maxHeapSize: "8G"
    gcMethod:
      type: G1
  resources:
    requests:
      memory: 10Gi
      cpu: 2000m
    limits:
      memory: 12Gi
      cpu: 4000m

worker:
  jvm:
    maxHeapSize: "8G"
    gcMethod:
      type: G1
  resources:
    requests:
      memory: 10Gi
      cpu: 2000m
    limits:
      memory: 12Gi
      cpu: 4000m

# Catalog 설정 (데이터 소스 연결)
catalogs:
  hive: |
    connector.name=hive
    hive.metastore.uri=thrift://hive-metastore:9083
    hive.s3.path-style-access=true
    hive.s3.endpoint=http://minio:9000
    hive.s3.aws-access-key=minioadmin
    hive.s3.aws-secret-key=minioadmin

  iceberg: |
    connector.name=iceberg
    iceberg.catalog.type=hive_metastore
    hive.metastore.uri=thrift://hive-metastore:9083

  postgresql: |
    connector.name=postgresql
    connection-url=jdbc:postgresql://postgres:5432/mydb
    connection-user=trino
    connection-password=trino-password

  kafka: |
    connector.name=kafka
    kafka.nodes=kafka-headless.data.svc.cluster.local:9092
    kafka.table-names=my-topic
    kafka.hide-internal-columns=false

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  hosts:
    - host: trino.example.com
      paths:
        - path: /
          pathType: Prefix
```

---

## 커스텀 Trino 이미지 빌드 (플러그인 추가 시)

추가 커넥터나 UDF가 필요한 경우에만 빌드합니다.

### Dockerfile

```dockerfile
FROM trinodb/trino:447

# 추가 플러그인 복사
COPY plugins/trino-custom-connector/ \
     /usr/lib/trino/plugin/custom-connector/

# 추가 JDBC 드라이버 (e.g., Oracle)
COPY jars/ojdbc11.jar \
     /usr/lib/trino/plugin/oracle/ojdbc11.jar

USER trino
```

### Jenkinsfile (커스텀 이미지 CI)

```groovy
pipeline {
    agent any

    environment {
        NEXUS_URL  = 'nexus.example.com:8082'
        IMAGE_NAME = 'myorg/trino-custom'
    }

    stages {
        stage('Checkout') {
            steps {
                git credentialsId: 'bitbucket-creds',
                    url: 'https://bitbucket.org/myorg/trino-custom.git',
                    branch: env.BRANCH_NAME
            }
        }

        stage('Helm Lint') {
            steps {
                sh 'helm lint charts/trino/'
            }
        }

        stage('Docker Build & Push') {
            when { branch 'main' }
            steps {
                script {
                    def tag = "447-${env.BUILD_NUMBER}"
                    withCredentials([usernamePassword(
                        credentialsId: 'nexus-docker-creds',
                        usernameVariable: 'USER',
                        passwordVariable: 'PASS'
                    )]) {
                        sh """
                            echo $PASS | docker login ${NEXUS_URL} -u $USER --password-stdin
                            docker build -t ${NEXUS_URL}/${IMAGE_NAME}:${tag} .
                            docker push ${NEXUS_URL}/${IMAGE_NAME}:${tag}
                        """
                    }
                    // Helm values 이미지 태그 업데이트
                    sh """
                        sed -i 's|repository:.*|repository: ${NEXUS_URL}/${IMAGE_NAME}|' charts/trino/values.yaml
                        sed -i 's|tag:.*|tag: "${tag}"|' charts/trino/values.yaml
                        git add charts/trino/values.yaml
                        git commit -m "ci: trino image tag ${tag}"
                        git push origin main
                    """
                }
            }
        }
    }
}
```

---

## Catalog 설정 변경 파이프라인

catalog 추가/변경은 `values.yaml` 수정 후 ArgoCD로 자동 배포됩니다.

```
개발자 → charts/trino/values.yaml 수정 (catalog 추가)
  → Bitbucket push
  → Jenkins: helm lint → git push
  → ArgoCD: ConfigMap 업데이트 → Trino Pod 재시작
```

> Trino는 catalog 설정 변경 시 **Coordinator/Worker 재시작**이 필요합니다.
> ArgoCD의 `selfHeal: true` 설정으로 ConfigMap 변경 시 자동으로 롤링 재시작됩니다.

---

## ArgoCD Application 등록

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trino
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    targetRevision: main
    path: charts/trino
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: data
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 민감 정보 관리 (Catalog 패스워드)

catalog 패스워드는 `values.yaml`에 직접 넣지 않고 K8s Secret으로 관리합니다.

```bash
# DB 패스워드 Secret 생성
kubectl create secret generic trino-catalog-secrets \
  --from-literal=postgresql-password=trino-password \
  --from-literal=s3-secret-key=minioadmin \
  -n data
```

```yaml
# values.yaml에서 Secret 참조
coordinator:
  additionalExposedPorts: {}
  extraEnv:
    - name: POSTGRESQL_PASSWORD
      valueFrom:
        secretKeyRef:
          name: trino-catalog-secrets
          key: postgresql-password
```

---

## 운영 명령어

```bash
# Trino Pod 상태
kubectl get pods -n data -l app.kubernetes.io/name=trino

# Coordinator 로그
kubectl logs -n data -l component=coordinator --tail=100

# Worker 로그
kubectl logs -n data -l component=worker --tail=100

# Trino CLI 접속
kubectl exec -it -n data \
  $(kubectl get pod -n data -l component=coordinator -o name | head -1) \
  -- trino --server localhost:8080

# 쿼리 내 CLI
trino> SHOW CATALOGS;
trino> SHOW SCHEMAS FROM hive;
trino> SELECT * FROM hive.default.my_table LIMIT 10;

# Trino UI 포트포워딩
kubectl port-forward -n data svc/trino 8080:8080
# 브라우저: http://localhost:8080
```

---

## 성능 튜닝 포인트

```yaml
# values.yaml 추가 설정
coordinator:
  additionalJVMConfig: |
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=32M
    -XX:+ExplicitGCInvokesConcurrent

server:
  coordinatorExtraConfig: |
    query.max-memory=50GB
    query.max-memory-per-node=10GB
    task.concurrency=8
    task.max-worker-threads=16
    spill-enabled=true
    spiller-spill-path=/tmp/trino-spill
```
