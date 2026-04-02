# OpenSearch 인덱스 필드 타입 충돌 해결

`log` 필드가 **object** 타입에서 **text** 타입으로 변경될 때, 기존 인덱스와 신규 인덱스 간에 매핑 충돌이 발생한다. 패턴(`logs-*`)으로 여러 날짜 인덱스를 묶어서 조회하면 쿼리 자체가 실패한다.

---

## 1. 문제 상황

### 발생 원인

날짜 롤오버(Rollover) 방식으로 인덱스를 관리하면, 날짜별로 인덱스가 분리된다.

```
logs-app-2025.05.01   →  log: object  ({"level": "info", "message": "..."})
logs-app-2025.05.02   →  log: object
...
logs-app-2025.06.01   →  log: text    ("INFO - something happened")  ← 타입 변경
logs-app-2025.06.02   →  log: text
```

`logs-app-*` 패턴으로 조회 시 OpenSearch는 동일 필드 이름에 서로 다른 타입이 존재함을 감지하고 쿼리를 거부한다.

### 오류 메시지 예시

```json
{
  "error": {
    "type": "search_phase_execution_exception",
    "reason": "Fielddata is disabled on text fields by default...",
    "caused_by": {
      "type": "illegal_argument_exception",
      "reason": "Fielddata is disabled on [log] in [logs-app-2025.05.01]"
    }
  }
}
```

또는

```json
{
  "error": {
    "type": "illegal_argument_exception",
    "reason": "mapper [log] of different type, current_type [ObjectMapper], merged_type [TextFieldMapper]"
  }
}
```

---

## 2. 해결 전략 선택

| 전략 | 적합한 상황 | 데이터 보존 |
|---|---|---|
| **A. 인덱스 별칭 분리** | 구/신 인덱스를 분리해서 조회해야 할 때 | O |
| **B. Reindex로 기존 인덱스 재색인** | 기존 데이터를 새 타입으로 통일하고 싶을 때 | O |
| **C. 충돌 인덱스 제외 (임시)** | 빠른 복구가 우선일 때 | O |
| **D. 인덱스 템플릿 재설정 + 신규 인덱스부터 적용** | 과거 데이터 조회 불필요할 때 | 신규만 |

---

## 3. 전략 A — 인덱스 별칭 분리

구 타입(object)과 신 타입(text) 인덱스를 서로 다른 별칭으로 나눠 Grafana 데이터소스를 2개로 운영한다.

```bash
# 구 인덱스(object 타입)에 별칭 추가
curl -X POST "https://<opensearch-host>:9200/_aliases" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{
    "actions": [
      {
        "add": {
          "indices": ["logs-app-2025.05.*"],
          "alias": "logs-app-legacy"
        }
      }
    ]
  }'

# 신 인덱스(text 타입)에 별칭 추가
curl -X POST "https://<opensearch-host>:9200/_aliases" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{
    "actions": [
      {
        "add": {
          "indices": ["logs-app-2025.06.*", "logs-app-2025.07.*"],
          "alias": "logs-app-current"
        }
      }
    ]
  }'
```

**Grafana 데이터소스를 2개로 분리해 사용**

| 데이터소스 이름 | Index name | 용도 |
|---|---|---|
| `OpenSearch-Legacy` | `logs-app-legacy` | 구 인덱스 조회 |
| `OpenSearch-Current` | `logs-app-current` | 신 인덱스 조회 |

---

## 4. 전략 B — Reindex로 기존 인덱스 재색인

기존 object 타입 인덱스를 text 타입으로 변환해 새 인덱스에 재색인한다.

### 4-1. 새 인덱스 템플릿 생성 (text 타입으로 명시)

```bash
curl -X PUT "https://<opensearch-host>:9200/_index_template/logs-app-v2" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{
    "index_patterns": ["logs-app-v2-*"],
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "refresh_interval": "30s"
      },
      "mappings": {
        "properties": {
          "@timestamp": { "type": "date" },
          "log":        { "type": "text" },
          "level":      { "type": "keyword" },
          "message":    { "type": "text" },
          "hostname":   { "type": "keyword" }
        }
      }
    }
  }'
```

### 4-2. 기존 인덱스 → 신 인덱스로 Reindex

```bash
# 단일 인덱스 reindex
curl -X POST "https://<opensearch-host>:9200/_reindex" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{
    "source": {
      "index": "logs-app-2025.05.01"
    },
    "dest": {
      "index": "logs-app-v2-2025.05.01"
    },
    "script": {
      "lang": "painless",
      "source": "
        if (ctx._source.log instanceof Map) {
          def logObj = ctx._source.log;
          ctx._source.log = logObj.containsKey(\"message\") ? logObj[\"message\"] : logObj.toString();
        }
      "
    }
  }'
```

> **script 설명:** 기존 `log` 필드가 object이면 `log.message` 값을 꺼내 text로 변환한다. object 구조에 따라 스크립트를 조정한다.

### 4-3. 날짜 범위 일괄 Reindex (Python 예제)

```python
from opensearchpy import OpenSearch
from datetime import date, timedelta

client = OpenSearch(
    hosts=[{"host": "<opensearch-host>", "port": 9200}],
    http_auth=("admin", "password"),
    use_ssl=True,
    verify_certs=False,
)

# 재색인할 날짜 범위
start = date(2025, 5, 1)
end   = date(2025, 5, 31)

script = """
if (ctx._source.log instanceof Map) {
    def m = ctx._source.log;
    ctx._source.log = m.containsKey('message') ? m['message'] : m.toString();
}
"""

current = start
while current <= end:
    date_str   = current.strftime("%Y.%m.%d")
    src_index  = f"logs-app-{date_str}"
    dest_index = f"logs-app-v2-{date_str}"

    # 소스 인덱스 존재 여부 확인
    if not client.indices.exists(index=src_index):
        current += timedelta(days=1)
        continue

    body = {
        "source": {"index": src_index},
        "dest":   {"index": dest_index},
        "script": {"lang": "painless", "source": script},
    }

    resp = client.reindex(body=body, wait_for_completion=True, request_timeout=300)
    print(f"{src_index} → {dest_index}: {resp['total']} docs, failures={resp['failures']}")

    current += timedelta(days=1)
```

### 4-4. 재색인 완료 후 별칭 교체 (Zero-downtime)

```bash
curl -X POST "https://<opensearch-host>:9200/_aliases" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{
    "actions": [
      { "remove": { "index": "logs-app-2025.05.*", "alias": "logs-app-current" } },
      { "add":    { "index": "logs-app-v2-2025.05.*", "alias": "logs-app-current" } }
    ]
  }'
```

---

## 5. 전략 C — 충돌 인덱스 제외 (임시 우회)

구 인덱스 조회가 불필요하다면, Grafana 데이터소스의 인덱스 패턴을 날짜 범위로 좁혀 충돌 인덱스를 제외한다.

```
# 기존 (충돌 발생)
logs-app-*

# 변경 (신 타입만 포함되는 날짜부터 지정)
logs-app-2025.06.*
```

**또는 OpenSearch Query에서 인덱스 직접 제외**

```bash
curl -X GET "https://<opensearch-host>:9200/logs-app-*,-logs-app-2025.05.*/_search" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{"query": {"match_all": {}}, "size": 5}'
```

---

## 6. 인덱스 템플릿 재설정 (근본 예방)

앞으로 동일한 문제가 재발하지 않으려면, **인덱스 템플릿에 필드 타입을 명시적으로 고정**해야 한다. 동적 매핑(dynamic mapping)에 의존하면 수집 데이터 형태가 바뀔 때마다 타입 충돌 위험이 생긴다.

```bash
curl -X PUT "https://<opensearch-host>:9200/_index_template/logs-app" \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d '{
    "index_patterns": ["logs-app-*"],
    "priority": 100,
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 1
      },
      "mappings": {
        "dynamic": "strict",
        "properties": {
          "@timestamp": { "type": "date" },
          "log":        { "type": "text" },
          "level":      { "type": "keyword" },
          "message":    { "type": "text" },
          "hostname":   { "type": "keyword" },
          "service":    { "type": "keyword" }
        }
      }
    }
  }'
```

> `"dynamic": "strict"` — 템플릿에 없는 필드가 들어오면 색인을 거부한다. 의도치 않은 타입 추론을 원천 차단한다.

---

## 7. 현재 매핑 상태 확인 커맨드 모음

```bash
# 특정 인덱스의 log 필드 타입 확인
curl -s "https://<opensearch-host>:9200/logs-app-2025.05.01/_mapping" \
  -u admin:password \
  | jq '.["logs-app-2025.05.01"].mappings.properties.log'

# 패턴 전체 인덱스의 log 필드 타입 비교
curl -s "https://<opensearch-host>:9200/logs-app-*/_mapping" \
  -u admin:password \
  | jq 'to_entries[] | {index: .key, log_type: .value.mappings.properties.log.type}'

# 타입 충돌 인덱스만 추출 (object 타입인 것)
curl -s "https://<opensearch-host>:9200/logs-app-*/_mapping" \
  -u admin:password \
  | jq 'to_entries[]
        | select(.value.mappings.properties.log.type == null)  # object는 type 필드 없음
        | .key'
```

---

## 8. 작업 순서 요약

```
1. 현재 충돌 범위 파악
   └─ _mapping API로 log 필드 타입이 다른 인덱스 목록 추출

2. 즉각 복구 (서비스 영향 최소화)
   └─ 전략 C: Grafana 인덱스 패턴을 신 타입 날짜 이후로 좁힘

3. 데이터 통합 (여유 있을 때)
   └─ 전략 B: Reindex로 구 인덱스를 신 타입으로 재색인
   └─ 별칭 교체로 Grafana 데이터소스 변경 없이 전환

4. 재발 방지
   └─ 인덱스 템플릿에 dynamic: strict + 전체 필드 타입 명시
```
