# Kafka - K8s CI/CD

## 배포 방식 선택

| 방식 | 장점 | 단점 |
|------|------|------|
| **Strimzi Operator** | CRD 기반, Kafka-native 관리 | 학습 곡선 |
| **Bitnami Helm Chart** | 간단한 설정 | Operator 없이 수동 관리 |

> 운영 환경에서는 **Strimzi Operator** 권장

---

## Strimzi Operator 방식

### Operator 설치 (Helm)

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update

helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --create-namespace
```

### Kafka 클러스터 CRD (values.yaml)

```yaml
# charts/kafka/templates/kafka-cluster.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-kafka
  namespace: kafka
spec:
  kafka:
    version: 3.7.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    storage:
      type: persistent-claim
      size: 50Gi
      class: standard
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      log.retention.hours: 168
    resources:
      requests:
        memory: 2Gi
        cpu: 500m
      limits:
        memory: 4Gi
        cpu: 2000m
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 10Gi
      class: standard
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

### Kafka Topic CRD

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-topic
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka
spec:
  partitions: 6
  replicas: 3
  config:
    retention.ms: 604800000    # 7일
    segment.bytes: 1073741824  # 1GB
```

---

## Bitnami Helm Chart 방식

### values.yaml 예시

```yaml
# charts/kafka/values.yaml
replicaCount: 3

kraft:
  enabled: true       # KRaft 모드 (ZooKeeper 없이)

persistence:
  enabled: true
  size: 50Gi
  storageClass: standard

resources:
  requests:
    memory: 2Gi
    cpu: 500m
  limits:
    memory: 4Gi
    cpu: 2000m

extraConfig: |
  log.retention.hours=168
  auto.create.topics.enable=false

metrics:
  kafka:
    enabled: true     # Prometheus JMX Exporter

service:
  type: ClusterIP
  ports:
    client: 9092
```

### Helm 설치

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install kafka bitnami/kafka \
  --namespace data \
  --create-namespace \
  -f charts/kafka/values.yaml
```

---

## CI 파이프라인 (Kafka 설정 변경)

Kafka 자체는 코드 빌드가 없지만, **설정 변경(Helm values)** 을 CI로 관리합니다.

```groovy
// Jenkinsfile (Kafka 설정 변경 시)
pipeline {
    agent any
    stages {
        stage('Lint Helm Chart') {
            steps {
                sh 'helm lint charts/kafka/'
            }
        }
        stage('Dry Run') {
            steps {
                sh '''
                    helm upgrade --install kafka bitnami/kafka \
                      --namespace data \
                      -f charts/kafka/values.yaml \
                      --dry-run
                '''
            }
        }
        stage('Commit & Push') {
            when { branch 'main' }
            steps {
                // values.yaml 변경사항을 ArgoCD가 감지하도록 Git push
                sh '''
                    git add charts/kafka/values.yaml
                    git commit -m "ci: update kafka config"
                    git push origin main
                '''
            }
        }
    }
}
```

---

## ArgoCD Application 등록

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kafka
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    targetRevision: main
    path: charts/kafka
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: data
  syncPolicy:
    automated:
      prune: false      # Kafka는 신중하게 prune 비활성화
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

> **주의**: Kafka StatefulSet은 `prune: false`로 설정해 실수로 데이터가 삭제되지 않도록 합니다.

---

## 운영 체크리스트

```bash
# Kafka Pod 상태 확인
kubectl get pods -n data -l app.kubernetes.io/name=kafka

# Kafka 브로커 연결 테스트
kubectl exec -it kafka-0 -n data -- \
  kafka-topics.sh --bootstrap-server localhost:9092 --list

# Topic 파티션 상태
kubectl exec -it kafka-0 -n data -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic my-topic

# Consumer Group Lag 확인
kubectl exec -it kafka-0 -n data -- \
  kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group my-consumer-group
```
