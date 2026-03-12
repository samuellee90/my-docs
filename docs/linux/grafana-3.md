# Kubernetes 컨테이너 로그 & 이벤트 수집 - Fluent Bit → OpenSearch → Grafana

컨테이너 JSON 로그와 Kubernetes 이벤트(Spark 포함)를 수집·저장·시각화하는 파이프라인을 정리합니다.

---

## 1. 전체 아키텍처

```
Kubernetes 노드 (DaemonSet)
├── Fluent Bit DaemonSet (노드당 1개)
│   ├── INPUT  : tail /var/log/containers/*.log
│   ├── FILTER : multiline (스택트레이스 재조합)
│   ├── FILTER : kubernetes (메타데이터 enrichment + JSON 파싱)
│   └── OUTPUT : OpenSearch → k8s-logs-YYYY.MM.DD
│
└── kubernetes-event-exporter (Deployment, 1개)
    ├── Spark 이벤트 → OpenSearch → spark-events-YYYY.MM.DD
    └── 전체 이벤트 → OpenSearch → k8s-events-YYYY.MM.DD

OpenSearch
├── k8s-logs-YYYY.MM.DD     (컨테이너 로그,  ISM 90일)
├── k8s-events-YYYY.MM.DD   (전체 이벤트,    ISM 30일)
└── spark-events-YYYY.MM.DD (Spark 이벤트,  ISM 90일)

Grafana
└── OpenSearch datasource → Spark 잡 모니터링 대시보드
```

---

## 2. Fluent Bit DaemonSet - 컨테이너 로그 수집

### 2.1 컨테이너 로그 경로와 런타임 포맷

| 런타임 | 로그 형식 | Fluent Bit parser |
|--------|-----------|-------------------|
| Docker | JSON 1줄 `{"log":"...","stream":"stdout","time":"..."}` | `docker` |
| containerd / CRI-O | `<timestamp> <stream> <F\|P> <message>` | `cri` |

> 현대 K8s 클러스터 대부분은 containerd를 사용하므로 `cri` 파서가 기본입니다.

모든 컨테이너 로그 파일 위치: `/var/log/containers/*.log`
(실제 경로인 `/var/log/pods/<namespace>_<pod>_<uid>/...`의 심링크)

### 2.2 DaemonSet - RBAC 및 볼륨 설정

```yaml
# serviceaccount / clusterrole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "events"]
    verbs: ["get", "list", "watch"]
---
# DaemonSet volumeMounts
volumeMounts:
  - name: varlog
    mountPath: /var/log
  - name: varlibdockercontainers
    mountPath: /var/lib/docker/containers
    readOnly: true
volumes:
  - name: varlog
    hostPath:
      path: /var/log
  - name: varlibdockercontainers
    hostPath:
      path: /var/lib/docker/containers
```

### 2.3 parsers.conf - 앱 JSON 로그 파서 정의

```ini
# parsers.conf

# containerd CRI 형식 (표준)
[PARSER]
    Name        cri
    Format      regex
    Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<log>.*)$
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L%z

# 앱이 JSON을 그대로 출력하는 경우 (Merge_Log로 자동 파싱 가능)
[PARSER]
    Name        json
    Format      json
    Time_Key    timestamp
    Time_Format %Y-%m-%dT%H:%M:%S.%LZ
    Time_Keep   On

# Spark 드라이버/익스큐터 로그 (log4j 형식)
[PARSER]
    Name        spark-log4j
    Format      regex
    Regex       ^(?<time>\d{2}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}) (?<level>[A-Z]+) (?<message>.*)$
    Time_Key    time
    Time_Format %y/%m/%d %H:%M:%S
```

### 2.4 fluent-bit.conf - 핵심 설정

```ini
[SERVICE]
    Flush         5
    Log_Level     info
    Parsers_File  parsers.conf
    HTTP_Server   On
    HTTP_Listen   0.0.0.0
    HTTP_Port     2020
    storage.path  /var/lib/fluent-bit/storage
    storage.backlog.mem_limit 50M
    # 멀티라인 버퍼 한도 (스택트레이스 재조합 최대 크기)
    multiline.flush_timeout 1000

# ─── INPUT ────────────────────────────────────────────────
[INPUT]
    Name              tail
    Tag               kube.*
    Path              /var/log/containers/*.log
    # containerd 클러스터는 cri, Docker는 docker
    multiline.parser  cri
    DB                /var/log/flb_kube.db
    Mem_Buf_Limit     50MB
    Skip_Long_Lines   On
    Refresh_Interval  10
    storage.type      filesystem

# ─── FILTER 1: 스택트레이스 멀티라인 재조합 ─────────────────
[FILTER]
    Name                  multiline
    Match                 kube.*
    multiline.key_content log
    # Go / Java / Python 스택트레이스를 하나의 레코드로 합침
    multiline.parser      go, java, python

# ─── FILTER 2: Kubernetes 메타데이터 enrichment ──────────────
[FILTER]
    Name              kubernetes
    Match             kube.*
    Kube_URL          https://kubernetes.default.svc:443
    Kube_CA_File      /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    Kube_Token_File   /var/run/secrets/kubernetes.io/serviceaccount/token
    # 앱이 JSON을 출력하면 log 필드를 파싱해서 최상위 필드로 병합
    Merge_Log         On
    # 병합 후 원본 log 필드 제거
    Keep_Log          Off
    # 파드 어노테이션으로 파서 지정 허용 (fluentbit.io/parser)
    K8S-Logging.Parser On
    # 파드 어노테이션으로 로그 제외 허용 (fluentbit.io/exclude: "true")
    K8S-Logging.Exclude On
    Labels            On
    Annotations       On
    # API 서버 대신 kubelet에서 메타데이터 조회 (대형 클러스터 부하 감소)
    Use_Kubelet       true
    Kubelet_Port      10250
    Buffer_Size       0

# ─── FILTER 3: 불필요한 시스템 필드 제거 ─────────────────────
[FILTER]
    Name    record_modifier
    Match   kube.*
    Remove_key stream
    Remove_key _p

# ─── OUTPUT: OpenSearch ───────────────────────────────────
[OUTPUT]
    Name                opensearch
    Match               kube.*
    Host                opensearch.logging.svc.cluster.local
    Port                9200
    HTTP_User           ${OPENSEARCH_USER}
    HTTP_Passwd         ${OPENSEARCH_PASSWORD}
    # k8s-logs-2025.03.13 형식 인덱스
    Logstash_Format     On
    Logstash_Prefix     k8s-logs
    Logstash_DateFormat %Y.%m.%d
    Time_Key            @timestamp
    Suppress_Type_Name  On
    tls                 On
    tls.verify          On
    Retry_Limit         5
    storage.total_limit_size 1G
```

---

## 3. 앱 JSON 로그 처리 - Merge_Log 동작 방식

앱이 구조화 JSON을 출력할 때 `Merge_Log On`이 적용되는 과정입니다.

**Merge_Log 전 (CRI 파서 직후):**
```json
{
  "log": "{\"level\":\"info\",\"msg\":\"request received\",\"duration_ms\":42}\n",
  "stream": "stdout",
  "kubernetes": { "pod_name": "myapp-7d8f9b-xkzpq", "namespace_name": "production" }
}
```

**Merge_Log On, Keep_Log Off 적용 후:**
```json
{
  "level": "info",
  "msg": "request received",
  "duration_ms": 42,
  "kubernetes": { "pod_name": "myapp-7d8f9b-xkzpq", "namespace_name": "production" }
}
```

### 파드 어노테이션으로 파서 지정

```yaml
# Deployment.spec.template.metadata.annotations
annotations:
  # 모든 컨테이너 / 모든 스트림에 json 파서 적용
  fluentbit.io/parser: "json"
  # stdout만 적용
  fluentbit.io/parser-stdout: "json"
  # 특정 컨테이너(myapp)만 적용
  fluentbit.io/parser-myapp: "spark-log4j"
  # 이 파드의 로그 전체 제외
  fluentbit.io/exclude: "true"
```

> `K8S-Logging.Parser On` 설정이 있어야 어노테이션이 동작합니다.

### Kubernetes 필터가 추가하는 필드 (kubernetes 키 하위)

```json
{
  "kubernetes": {
    "pod_name": "myapp-7d8f9b-xkzpq",
    "namespace_name": "production",
    "container_name": "myapp",
    "container_id": "abc123...",
    "host": "node-1",
    "labels": { "app": "myapp", "version": "1.2.3" },
    "annotations": { "fluentbit.io/parser": "json" },
    "container_image": "myapp:1.2.3"
  }
}
```

---

## 4. Kubernetes 이벤트 수집 - kubernetes-event-exporter

### 4.1 K8s 이벤트란

`kubectl get events`로 확인할 수 있는 클러스터 객체의 상태 변화 기록입니다.
기본적으로 **etcd에 1시간만 보관**되므로 외부 저장소로 내보내야 합니다.

```bash
kubectl get events -n spark-jobs --sort-by=.lastTimestamp
kubectl get events -n spark-jobs -o json | jq '.items[] | {reason, message, type}'
```

**주요 이벤트 필드:**

| 필드 | 설명 |
|------|------|
| `type` | `Normal` 또는 `Warning` |
| `reason` | 이벤트 원인 코드 (예: `Scheduled`, `OOMKilling`) |
| `message` | 사람이 읽을 수 있는 설명 |
| `involvedObject.kind` | 이벤트 대상 리소스 종류 (예: `Pod`, `SparkApplication`) |
| `involvedObject.name` | 이벤트 대상 리소스 이름 |
| `namespace` | 네임스페이스 |
| `reportingController` | 이벤트를 생성한 컨트롤러 (예: `spark-operator`) |
| `firstTimestamp` / `lastTimestamp` | 최초/최근 발생 시각 |
| `count` | 반복 횟수 |

### 4.2 Spark Operator 이벤트 종류

`spark-operator`가 `SparkApplication` CRD 라이프사이클마다 발생시키는 이벤트:

| reason | type | 설명 |
|--------|------|------|
| `SparkApplicationAdded` | Normal | CR 생성 |
| `SparkApplicationSubmitted` | Normal | 스케줄러에 제출됨 |
| `SparkDriverRunning` | Normal | 드라이버 파드 실행 중 |
| `SparkExecutorRunning` | Normal | 익스큐터 파드 실행 중 |
| `SparkApplicationCompleted` | Normal | 완료 |
| `SparkApplicationFailed` | **Warning** | 실패 |
| `SparkApplicationSubmissionFailed` | **Warning** | 제출 실패 |
| `SparkApplicationResubmitted` | Normal | 자동 재시작 |

---

### 4.3 kubernetes-event-exporter 설치

```bash
helm install spark-events-exporter \
  oci://registry-1.docker.io/bitnamicharts/kubernetes-event-exporter \
  --namespace event-exporter \
  --create-namespace \
  -f event-exporter-values.yaml
```

### 4.4 ConfigMap - 라우팅 설정

```yaml
# event-exporter-values.yaml
config:
  logLevel: info
  logFormat: json
  maxEventAgeSeconds: 60

  receivers:
    # 전체 이벤트 → 일반 인덱스
    - name: opensearch-all-events
      opensearch:
        hosts:
          - https://opensearch.logging.svc.cluster.local:9200
        index: k8s-events
        # Go time format 사용 (strftime 아님):
        #   2006=년, 01=월, 02=일
        indexFormat: "k8s-events-{2006.01.02}"
        username: "${OPENSEARCH_USER}"
        password: "${OPENSEARCH_PASSWORD}"
        # 이벤트 ID 기준 upsert (count 증가 시 중복 방지)
        useEventID: true
        deDot: true
        tls:
          insecureSkipVerify: false

    # Spark 전용 이벤트 → 별도 인덱스
    - name: opensearch-spark-events
      opensearch:
        hosts:
          - https://opensearch.logging.svc.cluster.local:9200
        index: spark-events
        indexFormat: "spark-events-{2006.01.02}"
        username: "${OPENSEARCH_USER}"
        password: "${OPENSEARCH_PASSWORD}"
        useEventID: true
        # Go template으로 문서 구조 커스터마이징
        layout:
          eventTime:         "{{ .GetTimestampMs }}"
          type:              "{{ .Type }}"
          reason:            "{{ .Reason }}"
          message:           "{{ .Message }}"
          namespace:         "{{ .Namespace }}"
          appName:           "{{ .InvolvedObject.Name }}"
          appKind:           "{{ .InvolvedObject.Kind }}"
          reportingController: "{{ .ReportingController }}"

  route:
    routes:
      # kube-system Normal 이벤트 드롭 (노이즈 감소)
      - drop:
          - namespace: "kube-system"
            type: "Normal"
          - namespace: "kube-public"
            type: "Normal"
        match:
          - receiver: "opensearch-all-events"

      # SparkApplication 이벤트 → Spark 전용 인덱스
      - match:
          - kind: "SparkApplication"
            receiver: "opensearch-spark-events"
          # spark-jobs 네임스페이스 파드 이벤트도 포함
          - kind: "Pod"
            namespace: "spark-jobs"
            receiver: "opensearch-spark-events"
```

> **indexFormat 주의**: `{2006.01.02}` 형식은 Go의 reference time 포맷입니다.
> `2006`=연도, `01`=월, `02`=일 (strftime의 `%Y.%m.%d`와 다름)

---

## 5. OpenSearch 인덱스 템플릿

### 컨테이너 로그 인덱스 템플릿

```bash
curl -X PUT "https://opensearch:9200/_index_template/k8s-logs-template" \
  -H "Content-Type: application/json" \
  -u admin:Admin@12345! \
  -d '{
    "index_patterns": ["k8s-logs-*"],
    "template": {
      "settings": {
        "number_of_shards": 2,
        "number_of_replicas": 1,
        "refresh_interval": "30s"
      },
      "mappings": {
        "properties": {
          "@timestamp":              { "type": "date" },
          "level":                   { "type": "keyword" },
          "msg":                     { "type": "text" },
          "message":                 { "type": "text" },
          "kubernetes": {
            "properties": {
              "namespace_name":      { "type": "keyword" },
              "pod_name":            { "type": "keyword" },
              "container_name":      { "type": "keyword" },
              "host":                { "type": "keyword" },
              "labels":              { "type": "object" }
            }
          }
        }
      }
    }
  }'
```

### Spark 이벤트 인덱스 템플릿

```bash
curl -X PUT "https://opensearch:9200/_index_template/spark-events-template" \
  -H "Content-Type: application/json" \
  -u admin:Admin@12345! \
  -d '{
    "index_patterns": ["spark-events-*", "k8s-events-*"],
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "refresh_interval": "10s"
      },
      "mappings": {
        "properties": {
          "eventTime":              { "type": "date" },
          "firstTimestamp":         { "type": "date" },
          "lastTimestamp":          { "type": "date" },
          "type":                   { "type": "keyword" },
          "reason":                 { "type": "keyword" },
          "message":                { "type": "text" },
          "namespace":              { "type": "keyword" },
          "reportingController":    { "type": "keyword" },
          "count":                  { "type": "integer" },
          "involvedObject": {
            "properties": {
              "kind":               { "type": "keyword" },
              "name":               { "type": "keyword" },
              "namespace":          { "type": "keyword" },
              "uid":                { "type": "keyword" }
            }
          }
        }
      }
    }
  }'
```

---

## 6. Grafana - Spark 이벤트 대시보드 쿼리

### Lucene 쿼리

```lucene
# spark-jobs 네임스페이스 Warning 이벤트 전체
type:Warning AND namespace:spark-jobs

# SparkApplication 실패 이벤트만
type:Warning AND involvedObject.kind:SparkApplication

# 특정 실패 reason
reason:SparkApplicationFailed OR reason:SparkApplicationSubmissionFailed

# OOM으로 죽은 익스큐터
reason:OOMKilling AND namespace:spark-jobs

# 특정 앱 이벤트 추적
involvedObject.name:"my-etl-job-20250313"
```

### PPL 쿼리

```sql
-- reason별 이벤트 건수 (파이차트 / 막대그래프)
source = spark-events-*
| where involvedObject.kind = 'SparkApplication'
| stats count() as cnt by reason
| sort - cnt

-- 시간별 Warning 이벤트 (시계열)
source = spark-events-*
| where type = 'Warning'
| stats count() as warning_count by span(lastTimestamp, 1h)
| sort lastTimestamp

-- 최근 실패 목록 (테이블 패널)
source = spark-events-*
| where reason = 'SparkApplicationFailed'
| fields lastTimestamp, namespace, involvedObject.name, reason, message
| sort - lastTimestamp
| head 50

-- 네임스페이스별 실패 집계
source = spark-events-*
| where reason = 'SparkApplicationFailed'
| stats count() as fail_count by namespace
| sort - fail_count
```

### 권장 대시보드 패널 구성

```
Row 1: Stat 패널 ─────────────────────────────────────────
  - 24h 내 SparkApplication 실패 건수
  - 24h 내 Warning 이벤트 건수
  - 현재 Running SparkApplication 수 (K8s 메트릭)

Row 2: 시계열 ─────────────────────────────────────────────
  - Spark 이벤트 시계열 (Normal vs Warning, date_histogram)

Row 3: 분포 ───────────────────────────────────────────────
  - reason별 이벤트 파이차트 (terms aggregation on reason.keyword)
  - 네임스페이스별 실패 막대그래프

Row 4: 테이블 / 로그 ──────────────────────────────────────
  - 최근 Warning 이벤트 목록 (시각, 앱명, reason, message)
  - 실시간 로그 뷰어 (컨테이너 로그와 이벤트 메시지 혼합)
```

---

## 7. ISM 정책 - 인덱스 수명 관리

```bash
curl -X PUT "https://opensearch:9200/_plugins/_ism/policies/k8s-log-lifecycle" \
  -H "Content-Type: application/json" \
  -u admin:Admin@12345! \
  -d '{
    "policy": {
      "default_state": "hot",
      "states": [
        {
          "name": "hot",
          "transitions": [{"state_name": "warm", "conditions": {"min_index_age": "7d"}}]
        },
        {
          "name": "warm",
          "actions": [
            {"replica_count": {"number_of_replicas": 1}},
            {"force_merge": {"max_num_segments": 1}}
          ],
          "transitions": [{"state_name": "delete", "conditions": {"min_index_age": "90d"}}]
        },
        {
          "name": "delete",
          "actions": [{"delete": {}}]
        }
      ]
    }
  }'
```

| 인덱스 패턴 | Hot | 삭제 |
|------------|-----|------|
| `k8s-logs-*` | 7일 | 90일 |
| `k8s-events-*` | 3일 | 30일 |
| `spark-events-*` | 7일 | 90일 |

---

## 8. 주의사항

### containerd vs Docker 파서
대부분의 현대 클러스터는 containerd를 사용합니다.
런타임에 따라 `multiline.parser cri` 또는 `Parser docker`를 선택하세요.

### Merge_Log 충돌 주의
앱 JSON에 `kubernetes`라는 키가 있으면 Fluent Bit의 kubernetes 메타데이터와 충돌합니다.
이 경우 `Merge_Log_Key app_log`로 네스팅 키를 지정해 충돌을 방지하세요.

```ini
[FILTER]
    Name          kubernetes
    Match         kube.*
    Merge_Log     On
    Merge_Log_Key app_log    # → app_log.level, app_log.msg, ...
    Keep_Log      Off
```

### kubernetes-event-exporter indexFormat (Go 시간 포맷)
```
strftime 포맷   →  Go time 포맷
%Y             →  2006
%m             →  01
%d             →  02
%H             →  15
```
예: `"spark-events-{2006.01.02}"` → `spark-events-2025.03.13`

### useEventID: true 권장
K8s 이벤트는 동일 이벤트가 count 증가와 함께 반복 전송될 수 있습니다.
`useEventID: true`를 설정하면 OpenSearch에 upsert로 처리되어 중복을 방지합니다.

---

## 참고 링크

- [Fluent Bit Kubernetes Filter 공식 문서](https://docs.fluentbit.io/manual/data-pipeline/filters/kubernetes)
- [Fluent Bit Kubernetes Events Input](https://docs.fluentbit.io/manual/pipeline/inputs/kubernetes-events)
- [Fluent Bit Multiline Parsing](https://docs.fluentbit.io/manual/data-pipeline/parsers/multiline-parsing)
- [kubernetes-event-exporter GitHub](https://github.com/resmoio/kubernetes-event-exporter)
- [Kubeflow Spark Operator GitHub](https://github.com/kubeflow/spark-operator)
- [OpenSearch ISM Policies](https://docs.opensearch.org/latest/im-plugin/ism/policies/)
