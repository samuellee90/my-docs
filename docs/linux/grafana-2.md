# Grafana 대시보드 구성 - OpenSearch + Prometheus 통합

## 1. 전체 구성 개요

```
┌──────────────────────────────────────────────────────────┐
│                   Grafana Dashboard                      │
│                                                          │
│   ┌─────────────────────┐   ┌─────────────────────┐     │
│   │   Prometheus 패널    │   │   OpenSearch 패널    │     │
│   │  (메트릭 시계열 시각화)│   │  (로그 검색/집계)    │     │
│   └──────────┬──────────┘   └──────────┬──────────┘     │
└──────────────┼───────────────────────── ┼───────────────┘
               │                          │
       ┌───────▼───────┐        ┌─────────▼──────────┐
       │   Prometheus  │        │     OpenSearch      │
       │  (메트릭 수집) │        │  (로그 저장/검색)   │
       └───────┬───────┘        └─────────┬──────────┘
               │                          │
       ┌───────▼───────┐        ┌─────────▼──────────┐
       │ Node Exporter │        │     Fluent Bit      │
       │ App Exporter  │        │   (로그 수집/전송)   │
       └───────────────┘        └────────────────────┘
```

| 컴포넌트 | 역할 | 데이터 유형 |
|---|---|---|
| **Prometheus** | 시계열 메트릭 수집/저장 | CPU, 메모리, 네트워크, 응답시간 등 숫자 지표 |
| **OpenSearch** | 로그 저장/전문 검색 | 애플리케이션 로그, 액세스 로그, 이벤트 텍스트 |
| **Grafana** | 통합 시각화/알림 | 두 데이터소스를 단일 대시보드에서 상관 분석 |

---

## 2. 데이터소스 설정

### Provisioning YAML

```yaml
# /etc/grafana/provisioning/datasources/datasources.yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus-uid
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      prometheusType: Prometheus
      prometheusVersion: 2.47.0
      timeInterval: "15s"
    editable: true

  - name: OpenSearch
    type: grafana-opensearch-datasource
    uid: opensearch-uid
    access: proxy
    url: http://opensearch:9200
    jsonData:
      version: "2.11.0"
      flavor: OpenSearch
      index: "logs-*"
      timeField: "@timestamp"
      pplEnabled: true
      logLevelField: "level"
      logMessageField: "message"
      maxConcurrentShardRequests: 5
    editable: true
```

### UI 설정 요약

**Prometheus**
- Type: `Prometheus`
- URL: `http://prometheus:9090`
- HTTP Method: `POST`

**OpenSearch**
- Type: `OpenSearch` (플러그인 설치 필요: `grafana-cli plugins install grafana-opensearch-datasource`)
- URL: `http://opensearch:9200`
- Index name: `logs-*`
- Time field name: `@timestamp`
- OpenSearch version: 실제 버전 입력

---

## 3. 패널별 쿼리 예시

### Prometheus: 시스템 메트릭

#### CPU 사용률

```promql
# 전체 평균
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 모드별 분리 (system / user / iowait)
rate(node_cpu_seconds_total{mode="system"}[5m]) * 100
rate(node_cpu_seconds_total{mode="user"}[5m]) * 100
rate(node_cpu_seconds_total{mode="iowait"}[5m]) * 100
```

#### 메모리 사용률

```promql
# 사용률 (%)
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
/ node_memory_MemTotal_bytes * 100

# 절대 사용량 (GiB)
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024 / 1024
```

#### 네트워크 트래픽

```promql
# 수신 (bps)
rate(node_network_receive_bytes_total{device!="lo"}[5m]) * 8

# 송신 (bps)
rate(node_network_transmit_bytes_total{device!="lo"}[5m]) * 8
```

#### HTTP 응답 시간 / 에러율

```promql
# P50 / P95 / P99 레이턴시
histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))

# 에러율 (5xx 비율, %)
sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (service)
/ sum(rate(http_requests_total[5m])) by (service) * 100
```

---

### OpenSearch: 로그 패널

#### Lucene 쿼리

```lucene
# 에러 로그
level:ERROR OR level:FATAL

# 특정 서비스 에러만
level:ERROR AND service:"payment-service"

# HTTP 5xx 에러
status_code:[500 TO 599]

# 헬스체크 봇 제외
NOT agent:"kube-probe/*" AND status_code:[400 TO 599]
```

#### PPL 쿼리

```sql
-- 시간별 에러 건수
source = logs-*
| where level = 'ERROR'
| stats count() as error_count by span(@timestamp, 1m)
| sort @timestamp

-- HTTP 상태코드별 집계
source = logs-*
| where status_code >= '400'
| stats count() as cnt by status_code, service
| sort -cnt

-- 에러율 계산
source = logs-*
| stats count() as total,
        count(if(level='ERROR', 1, null)) as errors
        by span(@timestamp, 5m)
| eval error_rate = errors / total * 100
| sort @timestamp

-- 상위 에러 메시지
source = logs-*
| where level = 'ERROR'
| stats count() as cnt by message
| sort -cnt
| head 10
```

---

## 4. 혼합(Mixed) 데이터소스 패널

단일 패널에서 Prometheus + OpenSearch를 동시에 쿼리할 수 있습니다.

```
패널 설정: Data source → -- Mixed --

Target A (Prometheus):
  datasource: Prometheus
  expr: rate(http_requests_total{service="$service", status_code=~"5.."}[5m])
  legend: "5xx Error Rate (Prometheus)"

Target B (OpenSearch):
  datasource: OpenSearch
  query: level:ERROR AND service:"$service"
  metric: Count
  legend: "Log Error Count (OpenSearch)"
```

### Annotation으로 로그 이벤트를 메트릭 그래프에 표시

메트릭 시계열 위에 에러 로그 발생 시점이 수직선으로 오버레이됩니다.

```json
// 대시보드 annotations 설정
{
  "name": "Error Log Events",
  "datasource": { "type": "grafana-opensearch-datasource", "uid": "opensearch-uid" },
  "enable": true,
  "iconColor": "red",
  "query": "level:ERROR",
  "timeField": "@timestamp",
  "titleField": "message",
  "tagsField": "service"
}
```

---

## 5. 대시보드 JSON 구조 예시

```json
{
  "uid": "infra-overview-001",
  "title": "Infrastructure Overview (Prometheus + OpenSearch)",
  "tags": ["prometheus", "opensearch", "infra"],
  "timezone": "browser",
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "templating": {
    "list": [
      {
        "name": "instance",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus-uid" },
        "query": "label_values(node_cpu_seconds_total, instance)",
        "refresh": 2,
        "includeAll": true
      },
      {
        "name": "service",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus-uid" },
        "query": "label_values(http_requests_total, service)",
        "refresh": 2,
        "multi": true,
        "includeAll": true
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "CPU 사용률 (%)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus-uid" },
      "targets": [
        {
          "refId": "A",
          "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode='idle', instance=~'$instance'}[5m])) * 100)",
          "legendFormat": "{{instance}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0, "max": 100,
          "thresholds": {
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 70 },
              { "color": "red", "value": 90 }
            ]
          }
        }
      }
    },
    {
      "id": 2,
      "title": "메모리 사용률 (%)",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus-uid" },
      "targets": [
        {
          "refId": "A",
          "expr": "(node_memory_MemTotal_bytes{instance=~'$instance'} - node_memory_MemAvailable_bytes{instance=~'$instance'}) / node_memory_MemTotal_bytes{instance=~'$instance'} * 100",
          "legendFormat": "{{instance}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 } }
    },
    {
      "id": 3,
      "title": "네트워크 트래픽 (bps)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 8, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus-uid" },
      "targets": [
        {
          "refId": "A",
          "expr": "rate(node_network_receive_bytes_total{instance=~'$instance', device!='lo'}[5m]) * 8",
          "legendFormat": "{{instance}} RX"
        },
        {
          "refId": "B",
          "expr": "rate(node_network_transmit_bytes_total{instance=~'$instance', device!='lo'}[5m]) * 8",
          "legendFormat": "{{instance}} TX"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "bps" } }
    },
    {
      "id": 4,
      "title": "HTTP 에러율 5xx (Prometheus)",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 8, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus-uid" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(http_requests_total{service=~'$service', status_code=~'5..'}[5m])) by (service) / sum(rate(http_requests_total{service=~'$service'}[5m])) by (service) * 100",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "percent" } }
    },
    {
      "id": 5,
      "title": "에러 로그 시계열 (OpenSearch)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 16, "w": 12, "h": 8 },
      "datasource": { "type": "grafana-opensearch-datasource", "uid": "opensearch-uid" },
      "targets": [
        {
          "refId": "A",
          "query": "level:ERROR AND service:$service",
          "timeField": "@timestamp",
          "metrics": [{ "id": "1", "type": "count" }],
          "bucketAggs": [
            {
              "id": "2",
              "type": "date_histogram",
              "field": "@timestamp",
              "settings": { "interval": "auto", "min_doc_count": "0" }
            }
          ]
        }
      ]
    },
    {
      "id": 6,
      "title": "HTTP 상태코드 분포 (OpenSearch)",
      "type": "piechart",
      "gridPos": { "x": 12, "y": 16, "w": 12, "h": 8 },
      "datasource": { "type": "grafana-opensearch-datasource", "uid": "opensearch-uid" },
      "targets": [
        {
          "refId": "A",
          "query": "*",
          "timeField": "@timestamp",
          "metrics": [{ "id": "1", "type": "count" }],
          "bucketAggs": [
            {
              "id": "2",
              "type": "terms",
              "field": "status_code.keyword",
              "settings": { "size": "10", "order": "desc", "orderBy": "1" }
            }
          ]
        }
      ]
    },
    {
      "id": 7,
      "title": "실시간 로그 뷰어 (OpenSearch)",
      "type": "logs",
      "gridPos": { "x": 0, "y": 24, "w": 24, "h": 10 },
      "datasource": { "type": "grafana-opensearch-datasource", "uid": "opensearch-uid" },
      "targets": [
        {
          "refId": "A",
          "query": "level:(ERROR OR WARN) AND service:$service",
          "timeField": "@timestamp",
          "metrics": [{ "id": "1", "type": "logs" }]
        }
      ],
      "options": {
        "showTime": true,
        "showLabels": true,
        "wrapLogMessage": true,
        "sortOrder": "Descending"
      }
    }
  ],
  "annotations": {
    "list": [
      {
        "name": "Error Log Events",
        "datasource": { "type": "grafana-opensearch-datasource", "uid": "opensearch-uid" },
        "enable": true,
        "iconColor": "red",
        "query": "level:ERROR",
        "timeField": "@timestamp",
        "titleField": "message",
        "tagsField": "service"
      }
    ]
  }
}
```

---

## 6. Provisioning으로 대시보드 코드 관리

### 디렉토리 구조

```
/etc/grafana/provisioning/
├── datasources/
│   └── datasources.yaml
├── dashboards/
│   ├── dashboard-provider.yaml
│   ├── infra-overview.json
│   └── logs-analysis.json
└── alerting/
    ├── rules.yaml
    └── contact-points.yaml
```

### 대시보드 프로바이더 설정

```yaml
# /etc/grafana/provisioning/dashboards/dashboard-provider.yaml
apiVersion: 1

providers:
  - name: "Infrastructure Dashboards"
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true          # UI 수정 허용
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: true

  - name: "Managed Dashboards"
    orgId: 1
    type: file
    disableDeletion: true
    allowUiUpdates: false         # 코드로만 관리 (UI 수정 불가)
    options:
      path: /etc/grafana/provisioning/dashboards/managed
```

### Kubernetes / Helm 환경

```yaml
# grafana-values.yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL

  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://prometheus-operated:9090
          isDefault: true
        - name: OpenSearch
          type: grafana-opensearch-datasource
          url: http://opensearch:9200
          jsonData:
            index: "logs-*"
            timeField: "@timestamp"
```

```yaml
# grafana-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: monitoring
  labels:
    grafana_dashboard: "1"    # sidecar가 자동 감지
data:
  infra-overview.json: |
    { ... }
```

---

## 7. 알림 설정

### Prometheus Alert Rules

```yaml
# /etc/prometheus/rules/infrastructure.yml
groups:
  - name: infrastructure_alerts
    interval: 1m
    rules:
      - alert: HighCPUUsage
        expr: >
          100 - (avg by(instance) (
            rate(node_cpu_seconds_total{mode="idle"}[5m])
          ) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU on {{ $labels.instance }}"
          description: "CPU {{ $value | humanize }}% > 80% for 5m"

      - alert: HighMemoryUsage
        expr: >
          (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
          / node_memory_MemTotal_bytes * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory on {{ $labels.instance }}"
          description: "Memory {{ $value | humanize }}% > 85%"

      - alert: HighHttpErrorRate
        expr: >
          sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (service)
          / sum(rate(http_requests_total[5m])) by (service) * 100 > 5
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "High error rate for {{ $labels.service }}"
          description: "Error rate {{ $value | humanize }}% > 5%"

      - alert: DiskSpaceLow
        expr: >
          (node_filesystem_avail_bytes{fstype!~"tmpfs"}
          / node_filesystem_size_bytes{fstype!~"tmpfs"}) * 100 < 15
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Low disk on {{ $labels.instance }}"
          description: "{{ $labels.mountpoint }} 잔여 {{ $value | humanize }}%"
```

### Grafana Alerting Provisioning

```yaml
# /etc/grafana/provisioning/alerting/rules.yaml
apiVersion: 1

groups:
  - orgId: 1
    name: "Infra Alerts"
    folder: "Alerts"
    interval: 1m
    rules:
      - uid: cpu-high-alert
        title: "CPU Usage High"
        condition: C
        data:
          - refId: A
            datasourceUid: prometheus-uid
            model:
              expr: >
                100 - (avg by(instance) (
                  rate(node_cpu_seconds_total{mode="idle"}[5m])
                ) * 100)
          - refId: B
            datasourceUid: "-100"    # Expression
            model:
              type: reduce
              expression: A
              reducer: last
          - refId: C
            datasourceUid: "-100"
            model:
              type: threshold
              expression: B
              conditions:
                - evaluator: { type: gt, params: [80] }
        for: 5m
        annotations:
          summary: "CPU 80% 초과"
          description: "{{ $labels.instance }}: {{ $values.B }}%"
        labels:
          severity: warning

contactPoints:
  - orgId: 1
    name: slack-ops
    receivers:
      - uid: slack-receiver
        type: slack
        settings:
          url: "https://hooks.slack.com/services/YOUR/WEBHOOK"
          channel: "#ops-alerts"
          title: "{{ .CommonLabels.alertname }}"
          text: "{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}"

policies:
  - orgId: 1
    receiver: slack-ops
    group_by: ["alertname", "instance"]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: slack-ops
        matchers:
          - severity = critical
```

---

## 8. 실무 팁

### 4 Golden Signals 대시보드 레이아웃

```
Row 1: Latency / Traffic / Errors / Saturation  ← 핵심 지표 4개 상단 고정
Row 2: 상세 메트릭 시계열 (Prometheus)
Row 3: 로그 패널 (OpenSearch)
Row 4: 실시간 로그 뷰어
```

### 메트릭-로그 상관 분석 패턴

```
1. USE Method
   CPU/메모리 포화도 (Prometheus) → 관련 에러 로그 (OpenSearch)
   같은 시간축에 나란히 배치

2. RED Method
   요청 비율/에러율/지연 (Prometheus) + 에러 상세 (OpenSearch)
   Annotation으로 에러 발생 시점 표시

3. 드릴다운 Data Links
   Prometheus 패널 클릭 → OpenSearch 로그 Explore로 이동
   URL 예시:
   /explore?left={"datasource":"opensearch-uid",
     "queries":[{"query":"service:${__field.labels.service} AND level:ERROR"}],
     "range":{"from":"${__from}","to":"${__to}"}}
```

### Prometheus Recording Rules (복잡한 쿼리 사전 계산)

```yaml
groups:
  - name: recording_rules
    rules:
      - record: instance:cpu_usage:rate5m
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
      - record: job:http_error_rate:rate5m
        expr: >
          sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (service)
          / sum(rate(http_requests_total[5m])) by (service)
```

### OpenSearch 인덱스 필드 설계 원칙

```json
{
  "mappings": {
    "properties": {
      "@timestamp":    { "type": "date" },
      "level":         { "type": "keyword" },
      "service":       { "type": "keyword" },
      "instance":      { "type": "keyword" },
      "trace_id":      { "type": "keyword" },
      "status_code":   { "type": "integer" },
      "response_time": { "type": "float" },
      "message":       { "type": "text", "analyzer": "standard" },
      "path":          { "type": "keyword" }
    }
  }
}
```

> **핵심 원칙**
> - 집계/필터 필드 → `keyword` 타입
> - 전문 검색 필드 → `text` 타입
> - `service`, `instance` 레이블을 Prometheus와 동일하게 맞춰두면 메트릭-로그 상관 분석 시 일관된 필터링 가능
> - `trace_id`를 공통 키로 두면 분산 추적과 연동 가능

---

## 참고 링크

- [Grafana OpenSearch Plugin 공식 문서](https://grafana.com/docs/plugins/grafana-opensearch-datasource/latest/)
- [Grafana Prometheus 데이터소스 설정](https://grafana.com/docs/grafana/latest/datasources/prometheus/configure/)
- [Grafana Provisioning 공식 문서](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Awesome Prometheus Alerts](https://samber.github.io/awesome-prometheus-alerts/)
- [OpenSearch + Grafana 연동 문서](https://docs.opensearch.org/latest/tools/grafana/)
