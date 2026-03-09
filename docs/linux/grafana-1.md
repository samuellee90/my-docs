# Fluent Bit → OpenSearch → Grafana 로그 파이프라인

## 1. 전체 아키텍처 개요

```
[ 애플리케이션 / 시스템 ]
         |
         v
   [ Fluent Bit ]     ← 로그 수집, 파싱, 필터링, 전송
         |
         v
  [ OpenSearch ]      ← 로그 저장, 인덱싱, 검색 엔진
         |
         v
    [ Grafana ]       ← 시각화, 대시보드, 알림
```

| 컴포넌트 | 역할 |
|---|---|
| **Fluent Bit** | 경량 로그 수집기. 파일/컨테이너/syslog에서 로그를 수집하고 파싱·필터링 후 OpenSearch로 전송 |
| **OpenSearch** | Lucene 기반 분산 검색 엔진. 로그를 인덱스 단위로 저장하고 풀텍스트 검색·집계·분석 제공 |
| **Grafana** | 시각화 플랫폼. OpenSearch를 데이터소스로 연결해 대시보드·차트·알림 구성 |

---

## 2. Fluent Bit 설정 예시

### 디렉토리 구조

```
/etc/fluent-bit/
├── fluent-bit.conf      # 메인 설정
└── parsers.conf         # 파서 정의
```

### parsers.conf

```ini
[PARSER]
    Name        json
    Format      json
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L
    Time_Keep   On

[PARSER]
    Name        nginx
    Format      regex
    Regex       ^(?<remote>[^ ]*) (?<host>[^ ]*) (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*).*$
    Time_Key    time
    Time_Format %d/%b/%Y:%H:%M:%S %z
    Types       code:integer size:integer

[PARSER]
    Name        docker
    Format      json
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L
    Time_Keep   On
```

### fluent-bit.conf

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

# ─── INPUT ───────────────────────────────
[INPUT]
    Name              tail
    Tag               nginx.access
    Path              /var/log/nginx/access.log
    Parser            nginx
    DB                /var/lib/fluent-bit/nginx.db
    Mem_Buf_Limit     10MB
    Skip_Long_Lines   On

[INPUT]
    Name              tail
    Tag               app.*
    Path              /var/log/app/*.log
    Parser            json
    DB                /var/lib/fluent-bit/app.db
    Mem_Buf_Limit     20MB

# ─── FILTER ──────────────────────────────
[FILTER]
    Name    record_modifier
    Match   *
    Record  hostname ${HOSTNAME}
    Record  environment production

[FILTER]
    Name    record_modifier
    Match   *
    Remove_key  stream
    Remove_key  _p

# ─── OUTPUT ──────────────────────────────
[OUTPUT]
    Name                opensearch
    Match               nginx.*
    Host                opensearch-host
    Port                9200
    Logstash_Format     On
    Logstash_Prefix     logs-nginx
    Logstash_DateFormat %Y.%m.%d
    Time_Key            @timestamp
    Suppress_Type_Name  On        # OpenSearch 2.0+ 필수
    HTTP_User           admin
    HTTP_Passwd         your_password
    tls                 Off
    Retry_Limit         10

[OUTPUT]
    Name                opensearch
    Match               app.*
    Host                opensearch-host
    Port                9200
    Logstash_Format     On
    Logstash_Prefix     logs-app
    Logstash_DateFormat %Y.%m.%d
    Time_Key            @timestamp
    Suppress_Type_Name  On
    HTTP_User           admin
    HTTP_Passwd         your_password
    tls                 Off
    Retry_Limit         10
```

### Docker Compose 전체 스택

```yaml
version: '3.8'

services:
  opensearch:
    image: opensearchproject/opensearch:2.17.0
    environment:
      - discovery.type=single-node
      - OPENSEARCH_INITIAL_ADMIN_PASSWORD=Admin@12345!
    ports:
      - "9200:9200"
    volumes:
      - opensearch-data:/usr/share/opensearch/data
    ulimits:
      memlock:
        soft: -1
        hard: -1

  fluent-bit:
    image: fluent/fluent-bit:3.1
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
      - ./parsers.conf:/fluent-bit/etc/parsers.conf
      - /var/log:/var/log:ro
    ports:
      - "2020:2020"
    depends_on:
      - opensearch
    restart: unless-stopped

  grafana:
    image: grafana/grafana:11.0.0
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_INSTALL_PLUGINS=grafana-opensearch-datasource
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - opensearch

volumes:
  opensearch-data:
  grafana-data:
```

---

## 3. OpenSearch 설정 포인트

### 인덱스 템플릿 사전 정의

동적 매핑에만 의존하면 동일 필드가 인덱스마다 다른 타입으로 매핑되어 쿼리 오류가 발생할 수 있다.

```bash
curl -X PUT "https://opensearch-host:9200/_index_template/logs-template" \
  -H "Content-Type: application/json" \
  -u admin:Admin@12345! \
  -d '{
    "index_patterns": ["logs-*"],
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "refresh_interval": "30s"
      },
      "mappings": {
        "properties": {
          "@timestamp": { "type": "date" },
          "hostname":   { "type": "keyword" },
          "level":      { "type": "keyword" },
          "message":    { "type": "text" },
          "code":       { "type": "integer" },
          "path":       { "type": "keyword" },
          "method":     { "type": "keyword" }
        }
      }
    }
  }'
```

### ISM 정책 - 오래된 인덱스 자동 삭제

```bash
curl -X PUT "https://opensearch-host:9200/_plugins/_ism/policies/logs-lifecycle" \
  -H "Content-Type: application/json" \
  -u admin:Admin@12345! \
  -d '{
    "policy": {
      "default_state": "hot",
      "states": [
        {
          "name": "hot",
          "transitions": [{ "state_name": "warm", "conditions": { "min_index_age": "7d" } }]
        },
        {
          "name": "warm",
          "actions": [{ "read_only": {} }, { "force_merge": { "max_num_segments": 1 } }],
          "transitions": [{ "state_name": "delete", "conditions": { "min_index_age": "30d" } }]
        },
        {
          "name": "delete",
          "actions": [{ "delete": {} }]
        }
      ]
    }
  }'
```

---

## 4. Grafana에서 OpenSearch 데이터소스 연결

### 플러그인 설치

```bash
grafana-cli plugins install grafana-opensearch-datasource
```

### UI 설정 항목

| 항목 | 값 예시 |
|---|---|
| URL | `http://opensearch-host:9200` |
| Basic Auth | On |
| User / Password | `admin` / `Admin@12345!` |
| Index name | `logs-nginx-*` |
| Time field name | `@timestamp` |
| OpenSearch version | `2.x` |
| Message field | `message` |

### Provisioning으로 코드 관리

```yaml
# /etc/grafana/provisioning/datasources/opensearch.yaml
apiVersion: 1
datasources:
  - name: OpenSearch-Logs
    type: grafana-opensearch-datasource
    access: proxy
    url: http://opensearch-host:9200
    basicAuth: true
    basicAuthUser: admin
    secureJsonData:
      basicAuthPassword: Admin@12345!
    jsonData:
      index: "logs-*"
      timeField: "@timestamp"
      opensearchVersion: "2.0.0"
      logMessageField: message
      logLevelField: level
    isDefault: true
```

---

## 5. 로그 쿼리 예시

### Lucene 쿼리

```lucene
# HTTP 5xx 에러
code:[500 TO 599]

# 특정 경로 에러
path:"/api/*" AND code:[400 TO 599]

# 특정 호스트 에러 로그
hostname:"web-server-01" AND level:error

# 헬스체크 제외
NOT agent:"kube-probe/*" AND code:200
```

### PPL 쿼리 (Piped Processing Language)

```sql
-- 최근 에러 상위 10건
source = logs-nginx-*
| where code >= 500
| sort - @timestamp
| head 10
| fields @timestamp, remote, method, path, code

-- 시간대별 에러 집계
source = logs-nginx-*
| where code >= 400
| stats count() as error_count by span(@timestamp, 1h), code
| sort @timestamp

-- 상위 에러 경로
source = logs-app-*
| where level = 'error'
| stats count() as cnt by path
| sort - cnt
| head 20
```

| 쿼리 언어 | 적합한 상황 |
|---|---|
| **Lucene** | 단순 키워드 검색, 필드 필터링, ElasticSearch 쿼리 재활용 |
| **PPL** | 집계, 파이프라인 처리, SQL에 익숙한 팀, 복잡한 통계 분석 |

---

## 6. 주의사항 및 팁

### `Suppress_Type_Name On` 필수
OpenSearch 2.0+에서 `_type` 필드가 제거됨. 설정하지 않으면 인덱싱 실패.

```ini
[OUTPUT]
    Name               opensearch
    Suppress_Type_Name On
```

### DB 파일로 읽기 위치 추적
Fluent Bit 재시작 시 중복 수집·누락 방지.

```ini
[INPUT]
    Name  tail
    DB    /var/lib/fluent-bit/pos.db
```

### `refresh_interval` 조정
로그 인덱스는 수집 성능이 중요하므로 기본값(1s) → 30s~60s로 늘리면 인덱싱 처리량 향상.

### 샤드 수 관리
날짜별 인덱스는 빠르게 쌓이므로 ISM 정책으로 30일 이후 인덱스를 반드시 삭제.

### Grafana 시간 필드 일치 확인
데이터소스의 `Time field name`이 실제 인덱스 필드명(`@timestamp`)과 정확히 일치해야 시계열 패널 동작.

---

## 참고 링크

- [Fluent Bit OpenSearch Output 공식 문서](https://docs.fluentbit.io/manual/data-pipeline/outputs/opensearch)
- [OpenSearch + Fluent Bit 시작 가이드](https://opensearch.org/blog/getting-started-with-fluent-bit-and-opensearch/)
- [Grafana OpenSearch 플러그인](https://grafana.com/grafana/plugins/grafana-opensearch-datasource/)
- [OpenSearch Grafana 연동 공식 문서](https://docs.opensearch.org/latest/tools/grafana/)
