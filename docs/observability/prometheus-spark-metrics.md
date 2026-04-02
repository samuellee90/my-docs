# K8s 환경에서 Prometheus Spark 메트릭 수집 파악하기

Grafana 대시보드에서 Prometheus를 데이터소스로 사용 중일 때, 실제로 어떤 메트릭이 수집되고 있는지 확인하는 방법을 정리한다.

---

## 1. 전체 수집 파이프라인 구조

```
[ Spark Executor / Driver ]
         |
         | /metrics  (JMX → Prometheus 포맷 노출)
         v
[ spark-metrics exporter / JMX Exporter ]
         |
         | scrape (15s ~ 1m 간격)
         v
[ Prometheus ]
         |
         | PromQL 쿼리
         v
[ Grafana 대시보드 ]
```

| 구성 요소 | 역할 |
|---|---|
| **JMX Exporter / Spark Prometheus Servlet** | Spark 내부 JMX 메트릭을 `/metrics` 엔드포인트로 HTTP 노출 |
| **ServiceMonitor / PodMonitor** | Prometheus Operator가 어떤 파드를 scrape할지 선언하는 CRD |
| **Prometheus scrape config** | 실제 수집 타깃 및 주기 설정 |
| **Prometheus TSDB** | 수집된 메트릭을 시계열로 저장 |
| **Grafana** | PromQL로 조회해 시각화 |

---

## 2. 현재 수집 중인 메트릭 확인 방법

### 2-1. Prometheus UI에서 직접 확인

Prometheus 웹 UI(`http://<prometheus-host>:9090`)에서 바로 조회할 수 있다.

**메트릭 목록 전체 조회**
```
http://<prometheus-host>:9090/api/v1/label/__name__/values
```

**Spark 관련 메트릭만 필터링**
```
# UI > Graph 탭에서 입력
{job=~"spark.*"}

# 또는 메트릭 이름 prefix로 검색
spark_
```

**특정 메트릭 존재 여부 확인**
```promql
# Executor 메모리 사용량
spark_executor_memoryUsed

# Active task 수
spark_executor_activeTasks

# GC 시간
spark_executor_totalGCTime
```

---

### 2-2. Prometheus API로 수집 메트릭 목록 추출

```bash
# 전체 메트릭 이름 목록
curl -s http://<prometheus-host>:9090/api/v1/label/__name__/values \
  | jq '.data[]' | sort

# spark 관련 메트릭만
curl -s http://<prometheus-host>:9090/api/v1/label/__name__/values \
  | jq '.data[] | select(startswith("spark"))' | sort

# 특정 job의 메트릭 목록
curl -s 'http://<prometheus-host>:9090/api/v1/series?match[]={job="spark-operator"}' \
  | jq '.data[]["__name__"]' | sort -u
```

---

### 2-3. Scrape Target(수집 대상) 확인

```bash
# 현재 scrape 중인 타깃 전체 조회
curl -s http://<prometheus-host>:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health: .health}'

# Spark 관련 타깃만
curl -s http://<prometheus-host>:9090/api/v1/targets \
  | jq '.data.activeTargets[] | select(.labels.job | test("spark")) | {job: .labels.job, instance: .labels.instance, health: .health}'
```

**UI에서 확인:** `http://<prometheus-host>:9090/targets`

---

## 3. K8s에서 수집 파이프라인 설정 확인

### 3-1. Prometheus Operator 사용 시 (일반적)

Prometheus Operator는 **ServiceMonitor** 또는 **PodMonitor** CRD로 scrape 대상을 선언한다.

```bash
# 클러스터 내 전체 ServiceMonitor 목록
kubectl get servicemonitor -A

# Spark 관련 ServiceMonitor 상세 확인
kubectl get servicemonitor -A | grep -i spark
kubectl describe servicemonitor <name> -n <namespace>

# PodMonitor 확인
kubectl get podmonitor -A | grep -i spark
kubectl describe podmonitor <name> -n <namespace>
```

**ServiceMonitor 예시**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: spark-operator-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: spark-operator       # 이 라벨을 가진 Service를 scrape
  endpoints:
    - port: metrics             # Service의 port 이름
      interval: 30s
      path: /metrics
  namespaceSelector:
    matchNames:
      - spark-operator
```

---

### 3-2. Prometheus ConfigMap / Secret에서 scrape_config 확인

Prometheus Operator 없이 직접 설정하는 경우 ConfigMap에 scrape 설정이 들어있다.

```bash
# Prometheus ConfigMap 찾기
kubectl get configmap -n monitoring | grep prometheus

# 내용 확인
kubectl get configmap prometheus-config -n monitoring -o yaml

# Secret으로 관리하는 경우
kubectl get secret -n monitoring | grep prometheus
kubectl get secret prometheus-config -n monitoring -o jsonpath='{.data.prometheus\.yml}' | base64 -d
```

**scrape_config 예시 (prometheus.yml)**
```yaml
scrape_configs:
  - job_name: 'spark-operator'
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - spark-operator
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
        action: replace
        regex: (\d+);((([0-9]+?)(\.|$)){4})
        replacement: $2:$1
        target_label: __address__
```

---

### 3-3. Prometheus Pod에서 실제 설정 파일 확인

```bash
# Prometheus Pod 이름 확인
kubectl get pod -n monitoring | grep prometheus

# Pod 내부 설정 파일 확인
kubectl exec -n monitoring <prometheus-pod> -- cat /etc/prometheus/prometheus.yml

# 동적으로 로드된 최종 설정 확인 (API)
curl http://<prometheus-host>:9090/api/v1/status/config \
  | jq '.data.yaml' -r
```

---

## 4. Spark 메트릭 노출 방식 확인

### 4-1. Spark 파드에서 직접 메트릭 엔드포인트 확인

```bash
# Spark driver/executor 파드 목록
kubectl get pod -n <spark-namespace> | grep spark

# 메트릭 포트 확인 (보통 4040, 8090 등)
kubectl describe pod <spark-driver-pod> -n <spark-namespace> | grep -A5 "Ports:"

# 파드 내 메트릭 엔드포인트 직접 조회
kubectl exec -n <spark-namespace> <spark-driver-pod> -- \
  curl -s http://localhost:8090/metrics

# 또는 port-forward로 로컬에서 확인
kubectl port-forward -n <spark-namespace> <spark-driver-pod> 8090:8090
curl http://localhost:8090/metrics | grep "^spark_"
```

### 4-2. Spark 파드 어노테이션 확인

파드에 Prometheus 어노테이션이 붙어있으면 자동으로 scrape된다.

```bash
kubectl get pod <spark-driver-pod> -n <spark-namespace> -o yaml | grep -A5 "annotations:"
```

```yaml
# 이런 어노테이션이 있으면 Prometheus가 자동 scrape
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8090"
  prometheus.io/path: "/metrics"
```

---

## 5. Grafana에서 수집 메트릭 탐색

### 5-1. Explore 탭에서 메트릭 브라우징

1. Grafana → **Explore** 탭
2. 데이터소스로 **Prometheus** 선택
3. `Metrics browser` 버튼 클릭 → `spark` 입력 후 자동완성으로 메트릭 목록 확인

### 5-2. 대시보드 패널의 PromQL 확인

기존 대시보드에서 어떤 메트릭을 쓰는지 역으로 파악할 수 있다.

1. 대시보드 패널 우상단 `...` → **Edit**
2. **Query** 탭에서 실제 PromQL 확인

### 5-3. 자주 쓰는 Spark PromQL 예시

```promql
# Executor 수
spark_executor_count

# Executor 메모리 사용률 (%)
spark_executor_memoryUsed / spark_executor_maxMemory * 100

# 전체 Active Task 수
sum(spark_executor_activeTasks)

# Job별 완료된 Task 수
spark_job_numCompletedTasks

# GC 오버헤드
rate(spark_executor_totalGCTime[5m]) / rate(spark_executor_totalDuration[5m]) * 100

# Stage 실패 수
spark_stage_numFailedTasks

# Shuffle Read/Write
rate(spark_executor_shuffleReadBytes[5m])
rate(spark_executor_shuffleWriteBytes[5m])
```

---

## 6. 수집 메트릭 전체 목록을 파일로 추출

```bash
# Prometheus에서 spark 메트릭 전체 이름을 파일로 저장
curl -s 'http://<prometheus-host>:9090/api/v1/label/__name__/values' \
  | jq -r '.data[] | select(startswith("spark"))' \
  > spark_metrics_list.txt

# 메트릭별 최신 값 샘플 포함해서 추출
curl -s 'http://<prometheus-host>:9090/api/v1/query?query={__name__=~"spark.*"}' \
  | jq -r '.data.result[] | "\(.metric.__name__)\t\(.value[1])"' \
  | sort -u \
  > spark_metrics_with_values.txt
```

---

## 7. 트러블슈팅

| 증상 | 확인 포인트 |
|---|---|
| Grafana에서 메트릭이 안 보임 | Prometheus Targets 페이지에서 해당 타깃이 `UP` 상태인지 확인 |
| 메트릭 이름이 바뀐 것 같음 | `relabel_configs`에서 메트릭 이름 변환 여부 확인 |
| 일부 Executor 메트릭 누락 | Spark dynamic allocation 시 Executor 파드가 종료되면서 메트릭 소실 → recording rule로 집계 권장 |
| scrape 주기가 너무 길어 실시간성 부족 | ServiceMonitor의 `interval` 값 단축 (기본 30s → 15s) |
| Prometheus 디스크 부족 | Spark 메트릭은 Executor 수에 비례해 cardinality가 높음 → label 수 최소화 |

---

## 참고

- [Prometheus Operator - ServiceMonitor](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1.ServiceMonitor)
- [Spark Monitoring 공식 문서](https://spark.apache.org/docs/latest/monitoring.html)
- [JMX Exporter](https://github.com/prometheus/jmx_exporter)
- [Prometheus HTTP API](https://prometheus.io/docs/prometheus/latest/querying/api/)
