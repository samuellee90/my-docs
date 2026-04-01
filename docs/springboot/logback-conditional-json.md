# Logback — ERROR/TID 조건부 JSON 로그 출력

K8s + OpenSearch + OpenSearch Dashboard 환경에서
`logback.xml`을 사용해 **ERROR 레벨이거나 MDC에 `tid` 값이 있는 경우에만** JSON 로그를 출력하는 설정입니다.

> 온프레미스(Linux + Elasticsearch + Kibana) 환경에서 ECS 설정으로 동적 JSON 출력하던 방식을
> K8s + OpenSearch 환경의 `logback.xml` 기반으로 전환한 구성입니다.

---

## 의존성 추가

**Maven (`pom.xml`)**
```xml
<!-- JSON 인코더 -->
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>7.4</version>
</dependency>

<!-- EvaluatorFilter용 Janino -->
<dependency>
    <groupId>org.codehaus.janino</groupId>
    <artifactId>janino</artifactId>
    <version>3.1.11</version>
</dependency>
```

**Gradle (`build.gradle`)**
```groovy
implementation 'net.logstash.logback:logstash-logback-encoder:7.4'
implementation 'org.codehaus.janino:janino:3.1.11'
```

---

## `logback.xml` 전체 설정

```xml
<configuration>

    <!-- ==========================================
         JSON Appender: ERROR 또는 tid 존재 시만 출력
         ========================================== -->
    <appender name="JSON_CONDITIONAL" class="ch.qos.logback.core.ConsoleAppender">

        <filter class="ch.qos.logback.core.filter.EvaluatorFilter">
            <evaluator class="ch.qos.logback.classic.boolex.JaninoEventEvaluator">
                <expression>
                    <!-- ERROR(40000) 이상이거나 MDC에 tid 값이 있을 때만 ACCEPT -->
                    level >= 40000
                    || (mdc != null
                        &amp;&amp; mdc.get("tid") != null
                        &amp;&amp; !mdc.get("tid").isEmpty())
                </expression>
            </evaluator>
            <OnMatch>ACCEPT</OnMatch>
            <OnMismatch>DENY</OnMismatch>
        </filter>

        <encoder class="net.logstash.logback.encoder.LogstashEncoder">
            <!-- OpenSearch에서 인식하는 표준 필드들 -->
            <timestampPattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</timestampPattern>
            <timeZone>UTC</timeZone>

            <!-- MDC 필드 명시적 포함 -->
            <includeMdcKeyName>tid</includeMdcKeyName>
            <includeMdcKeyName>userId</includeMdcKeyName>

            <!-- 커스텀 고정 필드 -->
            <customFields>{"app":"your-service-name","env":"production"}</customFields>

            <!-- 필드명 매핑 -->
            <fieldNames>
                <timestamp>@timestamp</timestamp>
                <message>message</message>
                <logger>logger</logger>
                <thread>thread</thread>
                <level>level</level>
                <levelValue>[ignore]</levelValue>
            </fieldNames>
        </encoder>
    </appender>

    <!-- ==========================================
         비동기 래핑 (K8s 환경 성능 최적화)
         ========================================== -->
    <appender name="ASYNC_JSON" class="ch.qos.logback.classic.AsyncAppender">
        <appender-ref ref="JSON_CONDITIONAL"/>
        <queueSize>512</queueSize>
        <discardingThreshold>0</discardingThreshold>
        <includeCallerData>false</includeCallerData>
    </appender>

    <root level="INFO">
        <appender-ref ref="ASYNC_JSON"/>
    </root>

</configuration>
```

---

## 동작 방식

```
로그 이벤트 발생
       │
       ▼
EvaluatorFilter 평가
       │
       ├─ level >= ERROR(40000)  → ACCEPT → JSON 출력
       ├─ MDC["tid"] 값 존재     → ACCEPT → JSON 출력
       └─ 둘 다 아님             → DENY   → 출력 안 함
```

### Logback 레벨 숫자값 참조

| 레벨 | 숫자값 |
|------|--------|
| TRACE | 5000 |
| DEBUG | 10000 |
| INFO | 20000 |
| WARN | 30000 |
| **ERROR** | **40000** |

---

## tid MDC 설정 예시 (Java 코드)

보통 `Filter` 또는 `HandlerInterceptor`에서 설정합니다.

```java
import org.slf4j.MDC;
import java.util.UUID;

// 요청 시작 시 tid 설정
MDC.put("tid", UUID.randomUUID().toString());

// 로그 사용
log.info("일반 로그 - JSON 미출력");    // tid 없으면 출력 안 됨
log.error("에러 로그 - JSON 출력");     // ERROR이므로 항상 출력
log.info("tid 있는 로그 - JSON 출력");  // tid 있으면 출력됨

// 요청 종료 시 정리
MDC.remove("tid");
// 또는 전체 제거: MDC.clear();
```

---

## OpenSearch Index Template 권장 매핑

```json
{
  "mappings": {
    "properties": {
      "@timestamp": { "type": "date" },
      "level":      { "type": "keyword" },
      "logger":     { "type": "keyword" },
      "message":    { "type": "text" },
      "tid":        { "type": "keyword" },
      "app":        { "type": "keyword" },
      "env":        { "type": "keyword" }
    }
  }
}
```

> `tid` 필드를 `keyword`로 설정해야 OpenSearch Dashboard에서 정확한 필터링이 됩니다.

---

## 주의사항

- XML 내 `&&` 는 반드시 `&amp;&amp;` 로 이스케이프해야 합니다.
- `EvaluatorFilter`는 `janino` 의존성이 없으면 동작하지 않습니다.
- `AsyncAppender`의 `discardingThreshold`를 `0`으로 설정하지 않으면
  큐가 80% 이상 찼을 때 WARN 이하 로그가 자동으로 버려집니다.
