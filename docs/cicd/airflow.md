# Apache Airflow - K8s CI/CD

## 배포 개요

Airflow는 **공식 Helm Chart**를 사용해 K8s에 배포하고,
DAG 코드는 **Git-sync** 방식으로 자동 배포합니다.

```
DAG Git Repo (Bitbucket)
      │
      │  Git-sync sidecar가 주기적으로 pull
      ▼
Airflow Worker/Scheduler Pod
```

---

## Helm Chart 설치

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm install airflow apache-airflow/airflow \
  --namespace workflow \
  --create-namespace \
  -f charts/airflow/values.yaml
```

---

## values.yaml 핵심 설정

```yaml
# charts/airflow/values.yaml

# Executor: K8s 환경에서는 KubernetesExecutor 권장
executor: KubernetesExecutor

# Airflow 이미지 (커스텀 패키지 포함 시 별도 빌드)
images:
  airflow:
    repository: nexus.example.com:8082/myorg/airflow-custom
    tag: 2.9.0
    pullPolicy: Always

imagePullSecrets:
  - name: nexus-pull-secret

# DAG: Git-sync 설정
dags:
  gitSync:
    enabled: true
    repo: https://bitbucket.org/myorg/airflow-dags.git
    branch: main
    rev: HEAD
    depth: 1
    maxFailures: 3
    subPath: dags/
    credentialsSecret: git-sync-creds    # Bitbucket 인증

# 데이터베이스 (외부 PostgreSQL 사용 권장)
data:
  metadataConnection:
    user: airflow
    pass: airflow-password
    host: postgres.workflow.svc.cluster.local
    port: 5432
    db: airflow

# Web 서버
webserver:
  replicas: 1
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
      cpu: 1000m

# Scheduler
scheduler:
  replicas: 1
  resources:
    requests:
      memory: 1Gi
      cpu: 500m

# Worker (KubernetesExecutor일 때 동적 Pod 생성)
workers:
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 4Gi
      cpu: 2000m

# Redis (CeleryExecutor 사용 시 필요)
redis:
  enabled: false    # KubernetesExecutor이면 불필요

# Persistence
logs:
  persistence:
    enabled: true
    size: 10Gi
```

---

## Git-sync 인증 Secret

```bash
# Bitbucket App Password 사용
kubectl create secret generic git-sync-creds \
  --from-literal=GIT_SYNC_USERNAME=<bitbucket-username> \
  --from-literal=GIT_SYNC_PASSWORD=<bitbucket-app-password> \
  -n workflow
```

---

## 커스텀 Airflow 이미지 빌드 (CI)

추가 Python 패키지가 필요한 경우 커스텀 이미지를 빌드합니다.

### Dockerfile

```dockerfile
FROM apache/airflow:2.9.0-python3.11

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev gcc && \
    apt-get clean

USER airflow

# 추가 패키지 설치
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
```

### requirements.txt

```
apache-airflow-providers-apache-spark==4.7.0
apache-airflow-providers-apache-kafka==1.3.0
apache-airflow-providers-trino==5.6.0
apache-airflow-providers-postgres==5.10.0
boto3==1.34.0
```

### Jenkinsfile (Airflow 이미지 CI)

```groovy
pipeline {
    agent any

    environment {
        NEXUS_URL  = 'nexus.example.com:8082'
        IMAGE_NAME = 'myorg/airflow-custom'
    }

    stages {
        stage('Checkout') {
            steps {
                git credentialsId: 'bitbucket-creds',
                    url: 'https://bitbucket.org/myorg/airflow-custom.git',
                    branch: 'main'
            }
        }

        stage('Docker Build & Push') {
            when { branch 'main' }
            steps {
                script {
                    def tag = "2.9.0-${env.BUILD_NUMBER}"
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
                    // Helm values 업데이트
                    sh """
                        sed -i 's|tag:.*|tag: "${tag}"|' charts/airflow/values.yaml
                        git add charts/airflow/values.yaml
                        git commit -m "ci: airflow image tag ${tag}"
                        git push origin main
                    """
                }
            }
        }
    }
}
```

---

## DAG 배포 파이프라인 (Git-sync)

DAG 코드는 별도의 Docker 빌드 없이 **Git push만으로 배포**됩니다.

```
개발자 → DAG 코드 수정 → Bitbucket push
          → git-sync sidecar가 60초 내 자동 반영
          → Scheduler가 새 DAG 감지
```

```bash
# Git-sync 주기 설정 (values.yaml)
dags:
  gitSync:
    wait: 60    # 60초마다 pull
```

---

## ArgoCD Application 등록

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: airflow
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    targetRevision: main
    path: charts/airflow
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: workflow
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 운영 명령어

```bash
# Airflow Pod 상태
kubectl get pods -n workflow

# Scheduler 로그
kubectl logs -n workflow -l component=scheduler --tail=100

# Airflow DB 마이그레이션 (업그레이드 후)
kubectl exec -it -n workflow \
  $(kubectl get pod -n workflow -l component=scheduler -o name | head -1) \
  -- airflow db migrate

# DAG 목록 확인
kubectl exec -it -n workflow \
  $(kubectl get pod -n workflow -l component=scheduler -o name | head -1) \
  -- airflow dags list

# 특정 DAG 수동 트리거
kubectl exec -it -n workflow \
  $(kubectl get pod -n workflow -l component=scheduler -o name | head -1) \
  -- airflow dags trigger my_dag_id
```
