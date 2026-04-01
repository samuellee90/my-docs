# ECS 구조화 로깅 vs LoggingEventCompositeJsonEncoder

Spring Boot의 `structured: ecs` 방식과 Logback의 `LoggingEventCompositeJsonEncoder` 방식의
작동 원리와 특징을 비교합니다.

---

## 1. ECS 구조화 로깅 (`structured: ecs`)

### 작동 원리

```
application.yml
  └─ logging.structured.format.console: ecs
         │
         ▼
Spring Boot Auto-Configuration
  └─ StructuredLoggingJsonEncoder (Boot 내장)
         │
         ▼
Logback Appender
  └─ 각 ILoggingEvent를 ECS 스펙 JSON으로 직렬화
         │
         ├─ MDC 값 존재 → 해당 필드 포함
         ├─ Throwable 존재 → error.type / error.message / error.stack_trace 포함
         └─ 둘 다 없으면 → 최소 필드만 출력 (동적 구성)
```

**Spring Boot가 내부적으로 처리하는 과정:**

1. `logging.structured.format.console: ecs` 설정 감지
2. `EcsStructuredLogFormatter`를 통해 ECS 스펙 필드명으로 매핑
3. 별도 `logback.xml` 없이 Boot의 기본 Appender에 JSON 포맷터를 교체
4. 이벤트마다 MDC·Throwable 유무를 검사해 해당 블록만 동적으로 포함

### 출력 필드 구조 (ECS 스펙)

```json
{
  "@timestamp": "2024-03-15T10:23:45.123Z",
  "log.level": "ERROR",
  "log.logger": "com.example.PaymentService",
  "process.pid": 12345,
  "process.thread.name": "http-nio-8080-exec-3",
  "service.name": "my-service",
  "service.version": "1.0.0",
  "service.environment": "production",
  "message": "결제 처리 실패",
  "transaction.id": "a1b2-c3d4",
  "error": {
    "type": "java.lang.RuntimeException",
    "message": "결제 오류",
    "stack_trace": "java.lang.RuntimeException: 결제 오류\n\tat ..."
  }
}
```

> `error` 블록은 Throwable이 있을 때만, `transaction.id` 같은 MDC 값은 MDC에 값이 있을 때만 동적으로 포함됩니다.

### 설정 방법

```yaml
# application.yml
logging:
  structured:
    format:
      console: ecs   # 콘솔 출력
      file: ecs      # 파일 출력 (선택)
  include-application-name: true
```

```yaml
# 서비스 식별 정보 (ECS service.* 필드)
spring:
  application:
    name: my-service

logging:
  structured:
    ecs:
      service:
        version: "1.0.0"
        environment: "production"
        node-name: "node-01"
```

### 특징

| 항목 | 내용 |
|------|------|
| 도입 버전 | Spring Boot 3.4+ |
| 외부 의존성 | 없음 (Boot 내장) |
| 필드명 표준 | ECS (Elastic Common Schema) 준수 |
| 동적 출력 | MDC·error 값 있을 때만 해당 블록 자동 포함 |
| 커스텀 필드 | MDC를 통해서만 추가 가능 |
| 조건부 출력 | 지원 안 함 (모든 로그 JSON 출력) |
| 대상 환경 | Elasticsearch / Kibana에 최적화 |

---

## 2. LoggingEventCompositeJsonEncoder

### 작동 원리

```
logback.xml
  └─ LoggingEventCompositeJsonEncoder
         │
         ▼
Provider 체인 순차 실행
  ├─ <timestamp/>       → @timestamp 필드 생성
  ├─ <logLevel/>        → level 필드 생성
  ├─ <message/>         → message 필드 생성
  ├─ <mdc/>             → MDC 키-값 전체 펼쳐서 삽입
  ├─ <arguments/>       → StructuredArguments 필드 삽입
  ├─ <stackTrace/>      → 예외 스택트레이스 삽입
  └─ <pattern/>         → 자유 형식 패턴으로 추가 필드 삽입
         │
         ▼
Jackson ObjectMapper로 최종 JSON 직렬화
  └─ Appender(Console / File / Rolling)로 전달
```

**Provider 체인 처리 흐름:**

1. `LoggingEventCompositeJsonEncoder`가 각 `ILoggingEvent`를 수신
2. 등록된 Provider 목록을 순서대로 순회하며 `JsonGenerator`에 필드를 씀
3. 각 Provider는 자신의 조건에 해당하는 필드만 선택적으로 출력
4. 모든 Provider 실행 후 JSON 객체를 닫고 바이트 배열로 직렬화

### 설정 방법

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>

    <!-- 시각 -->
    <timestamp>
      <fieldName>@timestamp</fieldName>
      <pattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</pattern>
      <timeZone>UTC</timeZone>
    </timestamp>

    <!-- 레벨 -->
    <logLevel><fieldName>level</fieldName></logLevel>

    <!-- 클래스명 -->
    <loggerName>
      <shortenedLoggerNameLength>36</shortenedLoggerNameLength>
    </loggerName>

    <!-- 스레드명 -->
    <threadName/>

    <!-- 메시지 -->
    <message/>

    <!-- 시스템 프로퍼티 / 고정 필드 -->
    <pattern>
      <pattern>
        {
          "app": "${spring.application.name:-unknown}",
          "env": "${SPRING_PROFILES_ACTIVE:-local}",
          "pid": "${PID:-0}"
        }
      </pattern>
    </pattern>

    <!-- MDC (tId 등 동적 값) -->
    <mdc/>

    <!-- StructuredArguments -->
    <arguments/>

    <!-- 예외 스택트레이스 -->
    <stackTrace>
      <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
        <rootCauseFirst>true</rootCauseFirst>
        <maxDepthPerThrowable>20</maxDepthPerThrowable>
      </throwableConverter>
    </stackTrace>

  </providers>
</encoder>
```

### 출력 필드 구조

```json
{
  "@timestamp": "2024-03-15T10:23:45.123Z",
  "level": "ERROR",
  "logger_name": "c.e.service.PaymentService",
  "thread_name": "http-nio-8080-exec-3",
  "message": "결제 처리 실패",
  "app": "my-service",
  "env": "production",
  "pid": "12345",
  "tId": "a1b2-c3d4",
  "stack_trace": "java.lang.RuntimeException: 결제 오류\n\tat ..."
}
```

### 특징

| 항목 | 내용 |
|------|------|
| 외부 의존성 | `logstash-logback-encoder` 필요 |
| 필드명 표준 | 자유 정의 (OpenSearch / 커스텀 스키마에 유연) |
| 동적 출력 | MDC 있을 때 자동 포함, `<stackTrace/>`는 Throwable 있을 때만 |
| 커스텀 필드 | Provider 추가 / Custom JsonProvider 구현으로 무제한 확장 |
| 조건부 출력 | `EvaluatorFilter` + Janino 조합으로 직접 구현 필요 |
| 대상 환경 | OpenSearch / Elasticsearch / 커스텀 로그 파이프라인 모두 호환 |

---

## 3. 구조 비교

### 처리 흐름

```
[ ECS ]
Log 호출 → ILoggingEvent → EcsStructuredLogFormatter
           (Spring Boot 내장)  → ECS 스펙 고정 구조로 직렬화 → 출력

[ LoggingEventCompositeJsonEncoder ]
Log 호출 → ILoggingEvent → Provider 체인 (순차 실행)
           (logback.xml 정의)  → Jackson JsonGenerator → 출력
```

### 핵심 차이점

| 항목 | ECS | LoggingEventCompositeJsonEncoder |
|------|-----|----------------------------------|
| 설정 위치 | `application.yml` | `logback.xml` |
| 의존성 | Spring Boot 3.4+ 내장 | `logstash-logback-encoder` 별도 추가 |
| 필드명 | ECS 스펙 고정 (`log.level`, `error.type` 등) | 자유 정의 |
| error 블록 | `error.type` / `error.message` / `error.stack_trace` 중첩 구조 | `stack_trace` 단일 문자열 (기본) |
| 동적 필드 | MDC 자동 포함, error 블록 자동 생성 | Provider별 조건 처리 |
| 조건부 출력 | 불가 (항상 JSON) | `EvaluatorFilter`로 구현 가능 |
| 커스텀 확장 | MDC 브릿징만 가능 | Custom JsonProvider로 무제한 확장 |
| 대상 플랫폼 | Elasticsearch / Kibana 최적화 | 플랫폼 무관 (OpenSearch 친화적) |
| `<pattern>` 내 동적 값 | 해당 없음 | 시스템 프로퍼티만 (`${VAR}`) |
| 스레드 내부 값 출력 | MDC 브릿징 필요 | MDC 또는 Custom JsonProvider |

### error 블록 구조 차이

**ECS** — 중첩 객체로 출력

```json
{
  "error": {
    "type": "java.lang.RuntimeException",
    "message": "결제 오류",
    "stack_trace": "java.lang.RuntimeException: ...\n\tat ..."
  }
}
```

**LoggingEventCompositeJsonEncoder** — 단일 문자열 (기본)

```json
{
  "stack_trace": "java.lang.RuntimeException: 결제 오류\n\tat ..."
}
```

ECS처럼 중첩 구조가 필요하다면 `<nestedField>` + Custom JsonProvider로 구현합니다.

```xml
<nestedField>
  <fieldName>error</fieldName>
  <providers>
    <provider class="com.example.logging.ErrorTypeJsonProvider"/>
    <provider class="com.example.logging.ErrorMessageJsonProvider"/>
    <stackTrace/>
  </providers>
</nestedField>
```

---

## 4. 환경별 선택 기준

```
온프레미스 Linux + Elasticsearch + Kibana
  → ECS 권장
    └─ ECS 필드명이 Kibana 기본 대시보드와 바로 연동됨
    └─ Spring Boot 3.4+ 이상이면 application.yml 한 줄로 적용

K8s + OpenSearch + OpenSearch Dashboard
  → LoggingEventCompositeJsonEncoder 권장
    └─ 필드명을 자유롭게 정의해 OpenSearch 인덱스 매핑과 맞출 수 있음
    └─ EvaluatorFilter로 조건부 JSON 출력 가능
    └─ Custom JsonProvider로 tId 등 내부 값 유연하게 추가 가능

두 환경 모두 사용 / 플랫폼 전환 예정
  → LoggingEventCompositeJsonEncoder
    └─ 필드명 매핑만 바꾸면 어느 플랫폼이든 적용 가능
```

---

## 5. 같이 보기

- [Logback ERROR/TID 조건부 JSON 출력](springboot/logback-conditional-json.md)
- [Logback 코드 내부 값을 JSON으로 출력](springboot/logback-internal-values.md)
- [logstash-logback-encoder Provider 필드 정리](springboot/logback-providers.md)
