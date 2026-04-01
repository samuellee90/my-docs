# logstash-logback-encoder 7.4 — Provider 필드 완전 정리

`net.logstash.logback:logstash-logback-encoder:7.4` 기준
`LoggingEventCompositeJsonEncoder`의 `<providers>` 내 사용 가능한 JSON Provider 정의, 출력 예시, 커스텀 방법을 정리합니다.

---

## 전체 Provider 목록

| XML 태그 | 클래스 (축약) | 설명 |
|----------|--------------|------|
| `<timestamp>` | `LoggingEventFormattedTimestampJsonProvider` | 로그 발생 시각 |
| `<message>` | `MessageJsonProvider` | 로그 메시지 본문 |
| `<logLevel>` | `LogLevelJsonProvider` | 로그 레벨 문자열 (INFO, ERROR …) |
| `<logLevelValue>` | `LogLevelValueJsonProvider` | 로그 레벨 숫자값 |
| `<loggerName>` | `LoggerNameJsonProvider` | Logger 클래스 이름 |
| `<threadName>` | `ThreadNameJsonProvider` | 스레드 이름 |
| `<mdc>` | `MdcJsonProvider` | MDC(Mapped Diagnostic Context) 전체 키-값 |
| `<arguments>` | `ArgumentsJsonProvider` | SLF4J 구조화 인자 (StructuredArgument) |
| `<stackTrace>` | `StackTraceJsonProvider` | 예외 스택트레이스 |
| `<tags>` | `TagsJsonProvider` | Markers 기반 태그 배열 |
| `<callerData>` | `CallerDataJsonProvider` | 호출 클래스·메서드·라인 정보 |
| `<context>` | `ContextJsonProvider` | Logback Context 프로퍼티 전체 |
| `<pattern>` | `LoggingEventPatternJsonProvider` | 자유 형식 패턴으로 JSON 필드 정의 |
| `<jsonMessage>` | `JsonMessageJsonProvider` | 메시지 자체가 JSON일 때 파싱해서 삽입 |
| `<nestedField>` | `LoggingEventNestedJsonProvider` | 지정 필드 하위에 중첩 JSON 삽입 |
| `<sequence>` | `SequenceJsonProvider` | 단조 증가 시퀀스 번호 |

---

## 각 Provider 상세

### 1. `<timestamp>`

로그 이벤트의 발생 시각을 출력합니다.

**기본 설정**
```xml
<providers>
  <timestamp/>
</providers>
```

**출력**
```json
{ "@timestamp": "2024-03-15T10:23:45.123+09:00" }
```

**커스텀** — 필드명·포맷·타임존 변경 가능
```xml
<timestamp>
  <fieldName>time</fieldName>
  <pattern>yyyy-MM-dd HH:mm:ss.SSS</pattern>
  <timeZone>Asia/Seoul</timeZone>
</timestamp>
```
```json
{ "time": "2024-03-15 10:23:45.123" }
```

---

### 2. `<message>`

`log.info("메시지")` 로 전달된 로그 메시지 본문입니다.

```xml
<message/>
```
```json
{ "message": "사용자 로그인 성공" }
```

**필드명 변경**
```xml
<message>
  <fieldName>msg</fieldName>
</message>
```

---

### 3. `<logLevel>` / `<logLevelValue>`

```xml
<logLevel/>
<logLevelValue/>
```
```json
{
  "level": "ERROR",
  "level_value": 40000
}
```

> `level_value`는 Logback 내부 숫자값: TRACE=5000, DEBUG=10000, INFO=20000, WARN=30000, ERROR=40000

**필드명 변경**
```xml
<logLevel>
  <fieldName>severity</fieldName>
</logLevel>
```

---

### 4. `<loggerName>`

```xml
<loggerName/>
```
```json
{ "logger_name": "com.example.service.UserService" }
```

**축약** — 마지막 N개 패키지 세그먼트만 출력
```xml
<loggerName>
  <shortenedLoggerNameLength>36</shortenedLoggerNameLength>
</loggerName>
```
```json
{ "logger_name": "c.e.service.UserService" }
```

---

### 5. `<threadName>`

```xml
<threadName/>
```
```json
{ "thread_name": "http-nio-8080-exec-3" }
```

---

### 6. `<mdc>`

`MDC.put("key", "value")`로 등록한 컨텍스트 정보를 JSON 필드로 출력합니다.

```java
MDC.put("traceId", "abc-123");
MDC.put("userId", "user-42");
log.info("주문 처리 완료");
```

```xml
<mdc/>
```
```json
{
  "traceId": "abc-123",
  "userId": "user-42"
}
```

**특정 키만 포함/제외**
```xml
<mdc>
  <includeMdcKeyName>traceId</includeMdcKeyName>
  <includeMdcKeyName>userId</includeMdcKeyName>
</mdc>
```

```xml
<mdc>
  <excludeMdcKeyName>sensitiveKey</excludeMdcKeyName>
</mdc>
```

**하위 필드로 중첩**
```xml
<mdc>
  <fieldName>context</fieldName>
</mdc>
```
```json
{ "context": { "traceId": "abc-123", "userId": "user-42" } }
```

---

### 7. `<arguments>`

SLF4J의 구조화 인자(`StructuredArgument`)를 JSON 필드로 출력합니다.
일반 `{}` 치환 인자가 아니라 `net.logstash.logback.argument` 패키지의 유틸을 사용해야 합니다.

```java
import static net.logstash.logback.argument.StructuredArguments.*;

log.info("주문 완료", keyValue("orderId", "ORD-001"), keyValue("amount", 15000));
```

```xml
<arguments/>
```
```json
{
  "message": "주문 완료",
  "orderId": "ORD-001",
  "amount": 15000
}
```

**주요 StructuredArguments 유틸**

| 메서드 | 출력 형태 | 예시 |
|--------|-----------|------|
| `keyValue("k", v)` | `"k": v` | `"orderId": "ORD-001"` |
| `kv("k", v)` | `keyValue` 축약 | 동일 |
| `value("k", v)` | 메시지에만 치환, JSON 필드로도 출력 | |
| `array("k", v1, v2)` | `"k": [v1, v2]` | `"tags": ["a","b"]` |
| `entries(map)` | Map 전체를 개별 필드로 펼쳐서 출력 | |
| `fields(obj)` | 객체 필드를 펼쳐서 출력 | |

---

### 8. `<stackTrace>`

예외 발생 시 스택트레이스를 출력합니다.

```xml
<stackTrace/>
```
```json
{ "stack_trace": "java.lang.NullPointerException: null\n\tat com.example.Service.method(Service.java:42)..." }
```

**한 줄로 압축 (Throwable Converter 적용)**
```xml
<stackTrace>
  <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
    <maxDepthPerThrowable>10</maxDepthPerThrowable>
    <maxLength>2048</maxLength>
    <shortenedClassNameLength>36</shortenedClassNameLength>
    <exclude>sun\.reflect\..*</exclude>
    <exclude>net\.sf\.cglib\..*</exclude>
    <rootCauseFirst>true</rootCauseFirst>
    <inlineHash>true</inlineHash>
  </throwableConverter>
</stackTrace>
```

---

### 9. `<tags>`

`Markers`를 배열 형태의 태그로 출력합니다.

```java
import org.slf4j.Marker;
import net.logstash.logback.marker.Markers;

Marker marker = Markers.append("tag", "payment");
log.info(marker, "결제 처리");
```

```xml
<tags/>
```
```json
{ "tags": ["payment"] }
```

---

### 10. `<callerData>`

로그를 호출한 클래스, 메서드, 파일, 라인 정보를 출력합니다.

> **주의**: 성능 비용이 크므로 개발/디버그 환경에서만 사용 권장

```xml
<callerData/>
```
```json
{
  "caller_class_name": "com.example.service.UserService",
  "caller_method_name": "login",
  "caller_file_name": "UserService.java",
  "caller_line_number": 87
}
```

---

### 11. `<context>`

Logback Context에 등록된 프로퍼티를 출력합니다.
`logback-spring.xml`의 `<property>`나 `System.setProperty`로 등록한 값이 포함됩니다.

```xml
<context/>
```
```json
{
  "HOSTNAME": "app-server-01",
  "APP_NAME": "my-service"
}
```

---

### 12. `<pattern>`

자유 형식으로 JSON 필드를 직접 정의합니다. Logback 패턴 문법(`%d`, `%level`, `%logger` 등)을 사용할 수 있습니다.

```xml
<pattern>
  <pattern>
    {
      "app": "my-service",
      "env": "${SPRING_PROFILES_ACTIVE:-local}",
      "pid": "${PID:-0}",
      "timestamp": "%d{yyyy-MM-dd'T'HH:mm:ss.SSSXXX}",
      "level": "%level",
      "logger": "%logger{36}",
      "thread": "%thread",
      "message": "%message"
    }
  </pattern>
</pattern>
```

---

### 13. `<jsonMessage>`

메시지 문자열 자체가 JSON인 경우, 파싱해서 필드로 삽입합니다.

```java
log.info("{\"event\":\"login\",\"userId\":\"user-42\"}");
```

```xml
<jsonMessage/>
```
```json
{ "event": "login", "userId": "user-42" }
```

> 메시지가 JSON이 아니면 일반 문자열로 폴백됩니다.

---

### 14. `<nestedField>`

다른 Provider들을 특정 필드 하위에 중첩시킵니다.

```xml
<nestedField>
  <fieldName>meta</fieldName>
  <providers>
    <loggerName/>
    <threadName/>
    <callerData/>
  </providers>
</nestedField>
```
```json
{
  "meta": {
    "logger_name": "com.example.UserService",
    "thread_name": "http-nio-8080-exec-1",
    "caller_line_number": 42
  }
}
```

---

### 15. `<sequence>`

로그마다 단조 증가하는 시퀀스 번호를 부여합니다. 로그 유실 탐지에 유용합니다.

```xml
<sequence/>
```
```json
{ "sequence": 1024 }
```

---

## 종합 설정 예시

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <timestamp>
      <fieldName>@timestamp</fieldName>
      <pattern>yyyy-MM-dd'T'HH:mm:ss.SSSXXX</pattern>
      <timeZone>Asia/Seoul</timeZone>
    </timestamp>
    <logLevel>
      <fieldName>level</fieldName>
    </logLevel>
    <pattern>
      <pattern>
        {
          "app": "${spring.application.name:-unknown}",
          "pid": "${PID:-0}",
          "env": "${spring.profiles.active:-local}"
        }
      </pattern>
    </pattern>
    <loggerName>
      <shortenedLoggerNameLength>36</shortenedLoggerNameLength>
    </loggerName>
    <threadName/>
    <message/>
    <mdc/>
    <arguments/>
    <stackTrace>
      <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
        <maxDepthPerThrowable>20</maxDepthPerThrowable>
        <rootCauseFirst>true</rootCauseFirst>
      </throwableConverter>
    </stackTrace>
  </providers>
</encoder>
```

**출력 예시**
```json
{
  "@timestamp": "2024-03-15T10:23:45.123+09:00",
  "level": "ERROR",
  "app": "my-service",
  "pid": "12345",
  "env": "prod",
  "logger_name": "c.e.service.UserService",
  "thread_name": "http-nio-8080-exec-3",
  "message": "결제 처리 실패",
  "traceId": "abc-123",
  "orderId": "ORD-001",
  "stack_trace": "java.lang.RuntimeException: 결제 오류\n\tat ..."
}
```
