# Apache Spark - K8s CI/CD

## 배포 방식

K8s에서 Spark는 두 가지 방식으로 실행합니다.

| 방식 | 특징 | 용도 |
|------|------|------|
| **Spark Operator** | CRD 기반, 선언적 관리 | 정기 배치 잡 |
| `spark-submit` on K8s | 직접 제출 | 임시 실행, 테스트 |

> 운영 환경에서는 **spark-operator** 권장

---

## Spark Operator 설치 (Helm)

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update

helm install spark-operator spark-operator/spark-operator \
  --namespace data \
  --create-namespace \
  --set webhook.enable=true \
  --set metrics.enable=true
```

---

## 커스텀 Spark 이미지 빌드 (CI)

Spark 잡의 Python/Scala 코드를 포함한 커스텀 이미지를 빌드합니다.

### Dockerfile (PySpark)

```dockerfile
FROM apache/spark-py:3.5.1-python3

# non-root 사용자 추가
USER root

# 추가 Python 패키지 설치
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# 잡 코드 복사
COPY jobs/ /app/jobs/
COPY jars/  /app/jars/     # 추가 JAR (JDBC 드라이버 등)

USER spark
WORKDIR /app
```

### requirements.txt

```
pyspark==3.5.1
delta-spark==3.2.0
boto3==1.34.0
```

### Jenkinsfile (Spark 이미지 CI)

```groovy
pipeline {
    agent any

    environment {
        NEXUS_URL  = 'nexus.example.com:8082'
        IMAGE_NAME = 'myorg/spark-custom'
    }

    stages {
        stage('Checkout') {
            steps {
                git credentialsId: 'bitbucket-creds',
                    url: 'https://bitbucket.org/myorg/spark-jobs.git',
                    branch: env.BRANCH_NAME
            }
        }

        stage('Lint / Test') {
            steps {
                sh 'python -m pytest tests/ -v'
            }
        }

        stage('Docker Build & Push') {
            when { branch 'main' }
            steps {
                script {
                    def tag = "3.5.1-${env.BUILD_NUMBER}"
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
                    // SparkApplication 이미지 태그 업데이트
                    sh """
                        sed -i 's|image:.*|image: ${NEXUS_URL}/${IMAGE_NAME}:${tag}|' \
                          charts/spark-jobs/templates/spark-application.yaml
                        git add charts/spark-jobs/
                        git commit -m "ci: spark image tag ${tag}"
                        git push origin main
                    """
                }
            }
        }
    }
}
```

---

## SparkApplication CRD (Helm Chart)

```
charts/spark-jobs/
├── Chart.yaml
├── values.yaml
└── templates/
    └── spark-application.yaml
```

### templates/spark-application.yaml

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: {{ .Values.jobName }}
  namespace: {{ .Values.namespace }}
spec:
  type: Python          # Python / Scala / Java
  mode: cluster
  image: {{ .Values.image }}
  imagePullPolicy: Always
  imagePullSecrets:
    - nexus-pull-secret
  mainApplicationFile: local:///app/jobs/main.py
  arguments:
    - "--date={{ .Values.date }}"

  sparkVersion: "3.5.1"

  driver:
    cores: 1
    memory: "2g"
    serviceAccount: spark-driver

  executor:
    cores: 2
    instances: 3
    memory: "4g"

  restartPolicy:
    type: OnFailure
    onFailureRetries: 2
    onFailureRetryInterval: 10
    onSubmissionFailureRetries: 5
    onSubmissionFailureRetryInterval: 20

  sparkConf:
    "spark.sql.extensions": "io.delta.sql.DeltaSparkSessionExtension"
    "spark.sql.catalog.spark_catalog": "org.apache.spark.sql.delta.catalog.DeltaCatalog"
    "spark.kubernetes.container.image.pullSecrets": "nexus-pull-secret"

  deps:
    jars:
      - local:///app/jars/postgresql-42.7.3.jar

  monitoring:
    exposeDriverMetrics: true
    exposeExecutorMetrics: true
    prometheus:
      jmxExporterJar: "/prometheus/jmx_prometheus_javaagent.jar"
      port: 8090
```

### values.yaml

```yaml
jobName: spark-etl-job
namespace: data
image: nexus.example.com:8082/myorg/spark-custom:latest
date: "2024-01-01"
```

---

## RBAC 설정 (Spark Driver용 ServiceAccount)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spark-driver
  namespace: data
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spark-driver-role
  namespace: data
rules:
  - apiGroups: [""]
    resources: [pods, services, configmaps]
    verbs: [create, get, list, watch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spark-driver-rolebinding
  namespace: data
subjects:
  - kind: ServiceAccount
    name: spark-driver
roleRef:
  kind: Role
  name: spark-driver-role
  apiGroup: rbac.authorization.k8s.io
```

---

## ArgoCD Application 등록

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spark-jobs
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    targetRevision: main
    path: charts/spark-jobs
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
```

---

## Airflow에서 Spark 잡 트리거

```python
# airflow_dag/spark_etl.py
from airflow import DAG
from airflow.providers.apache.spark.operators.spark_kubernetes import SparkKubernetesOperator
from datetime import datetime

with DAG(
    dag_id='spark_etl',
    schedule_interval='0 2 * * *',
    start_date=datetime(2024, 1, 1),
    catchup=False
) as dag:

    spark_job = SparkKubernetesOperator(
        task_id='run_etl',
        namespace='data',
        application_file='spark-application.yaml',
        kubernetes_conn_id='kubernetes_default',
        do_xcom_push=False
    )
```

---

## 운영 명령어

```bash
# SparkApplication 목록
kubectl get sparkapplication -n data

# 잡 상태 확인
kubectl describe sparkapplication spark-etl-job -n data

# Driver Pod 로그
kubectl logs -n data -l spark-role=driver --tail=200

# 완료된 잡 삭제
kubectl delete sparkapplication spark-etl-job -n data

# spark-submit 직접 실행 (임시)
spark-submit \
  --master k8s://https://<k8s-api-server>:6443 \
  --deploy-mode cluster \
  --conf spark.kubernetes.container.image=nexus.example.com:8082/myorg/spark-custom:latest \
  --conf spark.kubernetes.namespace=data \
  local:///app/jobs/main.py
```
