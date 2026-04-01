# Logback — 코드 내부 값을 JSON 로그로 출력하기

`LoggingEventCompositeJsonEncoder`의 `<pattern>` 프로바이더는 **시스템 프로퍼티(`${VAR}`)만** 참조할 수 있습니다.
스레드 내부 값(tId, 커스텀 ThreadLocal 등)을 JSON 로그로 뽑으려면 아래 방법 중 하나를 사용해야 합니다.

> **배경**: 기존 `application.yml`의 `structured: ecs` 설정은 `tId`·`error` 필드가 존재할 때만 동적으로 JSON을 출력했습니다.
> `LoggingEventCompositeJsonEncoder`에서도 동일한 동작을 구현합니다.

---

## 방법 비교

| 방법 | 설정 위치 | 적합한 경우 |
|------|-----------|------------|
| **MDC** | Filter/Interceptor | tId처럼 요청 단위로 관리하는 값 (권장) |
| **StructuredArguments** | 로그 호출부 | 특정 로그 라인에만 필요한 값 |
| **Custom JsonProvider** | logback.xml + Java | ThreadLocal 등 코드 내부 값을 전역 출력 |
| **Custom Converter** | logback.xml + Java | `<pattern>` 안에서 `%tId` 형태로 사용 |

---

## 방법 1. MDC — 요청 단위 값 관리 (권장)

`MDC`는 스레드에 바인딩된 키-값 저장소로, `<mdc/>` 프로바이더가 자동으로 JSON 필드로 출력합니다.
ECS의 `tId` 동작과 가장 유사합니다.

### Filter / Interceptor에서 MDC 설정

```java
import org.slf4j.MDC;
import jakarta.servlet.*;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.util.UUID;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class TransactionIdFilter implements Filter {

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        try {
            // tId: 요청마다 고유한 트랜잭션 ID 생성
            MDC.put("tId", UUID.randomUUID().toString());
            chain.doFilter(request, response);
        } finally {
            MDC.remove("tId"); // 반드시 정리
        }
    }
}
```

> 기존 코드에 이미 ThreadLocal로 tId를 관리하고 있다면,
> Filter/Interceptor에서 `MDC.put("tId", YourThreadLocal.get())`으로 브릿징하면 됩니다.

### logback.xml 설정

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <timestamp>
      <fieldName>@timestamp</fieldName>
      <pattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</pattern>
      <timeZone>UTC</timeZone>
    </timestamp>
    <logLevel><fieldName>level</fieldName></logLevel>
    <loggerName/>
    <threadName/>
    <message/>

    <!-- MDC 전체 또는 특정 키만 출력 -->
    <mdc>
      <includeMdcKeyName>tId</includeMdcKeyName>
    </mdc>

    <!-- 예외 정보 (error.type, error.message, stack_trace) -->
    <stackTrace>
      <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
        <rootCauseFirst>true</rootCauseFirst>
        <maxDepthPerThrowable>20</maxDepthPerThrowable>
      </throwableConverter>
    </stackTrace>
  </providers>
</encoder>
```

### 출력 예시

```json
{
  "@timestamp": "2024-03-15T10:23:45.123Z",
  "level": "ERROR",
  "logger_name": "c.e.service.PaymentService",
  "thread_name": "http-nio-8080-exec-3",
  "message": "결제 처리 실패",
  "tId": "a1b2-c3d4-e5f6",
  "stack_trace": "java.lang.RuntimeException: 결제 오류\n\tat ..."
}
```

---

## 방법 2. StructuredArguments — 로그 호출부에서 직접 전달

특정 로그 라인에만 동적 값을 붙여야 할 때 사용합니다.

```java
import static net.logstash.logback.argument.StructuredArguments.*;

// 로그 호출 시 keyValue로 전달
log.info("주문 완료", keyValue("tId", currentTId), keyValue("orderId", order.getId()));
log.error("오류 발생", keyValue("tId", currentTId), keyValue("errorCode", e.getCode()), e);
```

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <timestamp/>
    <logLevel/>
    <message/>
    <arguments/> <!-- StructuredArguments 출력 -->
    <stackTrace/>
  </providers>
</encoder>
```

```json
{
  "message": "주문 완료",
  "tId": "a1b2-c3d4",
  "orderId": "ORD-001"
}
```

---

## 방법 3. Custom JsonProvider — ThreadLocal 값을 전역 출력

기존 코드에 ThreadLocal로 관리되는 tId가 있고, 모든 로그에 자동으로 출력하고 싶을 때 사용합니다.

### ThreadLocal 관리 클래스 (기존 코드 예시)

```java
public class TransactionContext {
    private static final ThreadLocal<String> TID = new ThreadLocal<>();

    public static void set(String tId) { TID.set(tId); }
    public static String get() { return TID.get(); }
    public static void clear() { TID.remove(); }
}
```

### Custom JsonProvider 구현

```java
import ch.qos.logback.classic.spi.ILoggingEvent;
import com.fasterxml.jackson.core.JsonGenerator;
import net.logstash.logback.composite.AbstractJsonProvider;
import java.io.IOException;

public class TransactionIdJsonProvider extends AbstractJsonProvider<ILoggingEvent> {

    private String fieldName = "tId";

    @Override
    public void writeTo(JsonGenerator generator, ILoggingEvent event) throws IOException {
        String tId = TransactionContext.get(); // ThreadLocal에서 직접 조회
        if (tId != null && !tId.isEmpty()) {
            generator.writeStringField(fieldName, tId);
        }
        // null이면 필드 자체를 쓰지 않음 → ECS의 동적 출력과 동일한 동작
    }

    public void setFieldName(String fieldName) {
        this.fieldName = fieldName;
    }
}
```

### logback.xml에서 커스텀 프로바이더 등록

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <timestamp><fieldName>@timestamp</fieldName></timestamp>
    <logLevel><fieldName>level</fieldName></logLevel>
    <message/>

    <!-- 커스텀 프로바이더 -->
    <provider class="com.example.logging.TransactionIdJsonProvider">
      <fieldName>tId</fieldName>
    </provider>

    <stackTrace/>
  </providers>
</encoder>
```

---

## 방법 4. Custom Converter — `<pattern>` 안에서 `%tId`로 사용

`<pattern>` 프로바이더 안에서 커스텀 변환자를 `%tId` 형태로 쓰고 싶을 때 사용합니다.

### Custom Converter 구현

```java
import ch.qos.logback.classic.pattern.ClassicConverter;
import ch.qos.logback.classic.spi.ILoggingEvent;

public class TransactionIdConverter extends ClassicConverter {

    @Override
    public String convert(ILoggingEvent event) {
        // MDC에서 가져오거나 ThreadLocal에서 직접 조회
        String tId = event.getMDCPropertyMap().get("tId");
        return tId != null ? tId : "";
    }
}
```

### logback.xml에서 등록 및 사용

```xml
<configuration>

  <!-- 커스텀 변환자 등록 -->
  <conversionRule conversionWord="tId"
                  converterClass="com.example.logging.TransactionIdConverter"/>

  <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
      <providers>
        <pattern>
          <pattern>
            {
              "@timestamp": "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z'}",
              "level": "%level",
              "tId": "%tId",
              "message": "%message"
            }
          </pattern>
        </pattern>
        <stackTrace/>
      </providers>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="JSON"/>
  </root>

</configuration>
```

---

## ECS처럼 tId 또는 ERROR일 때만 JSON 출력

기존 `structured: ecs`와 동일하게 **조건부 출력**을 구현합니다.

```xml
<configuration>

  <appender name="JSON_CONDITIONAL" class="ch.qos.logback.core.ConsoleAppender">

    <!-- ERROR이거나 tId가 MDC에 있을 때만 출력 -->
    <filter class="ch.qos.logback.core.filter.EvaluatorFilter">
      <evaluator class="ch.qos.logback.classic.boolex.JaninoEventEvaluator">
        <expression>
          level >= 40000
          || (mdc != null
              &amp;&amp; mdc.get("tId") != null
              &amp;&amp; !mdc.get("tId").isEmpty())
        </expression>
      </evaluator>
      <OnMatch>ACCEPT</OnMatch>
      <OnMismatch>DENY</OnMismatch>
    </filter>

    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
      <providers>
        <timestamp><fieldName>@timestamp</fieldName></timestamp>
        <logLevel><fieldName>level</fieldName></logLevel>
        <loggerName/>
        <message/>
        <mdc>
          <includeMdcKeyName>tId</includeMdcKeyName>
        </mdc>
        <!-- error 필드 (ECS의 error.type, error.message 대응) -->
        <stackTrace>
          <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
            <rootCauseFirst>true</rootCauseFirst>
            <maxDepthPerThrowable>20</maxDepthPerThrowable>
          </throwableConverter>
        </stackTrace>
      </providers>
    </encoder>
  </appender>

  <appender name="ASYNC" class="ch.qos.logback.classic.AsyncAppender">
    <appender-ref ref="JSON_CONDITIONAL"/>
    <queueSize>512</queueSize>
    <discardingThreshold>0</discardingThreshold>
  </appender>

  <root level="INFO">
    <appender-ref ref="ASYNC"/>
  </root>

</configuration>
```

---

## 방법 선택 기준

```
tId가 요청 단위로 관리되는 트랜잭션 ID?
  └─ YES → 방법 1 (MDC) — Filter에서 put/remove
  └─ NO (진짜 Thread.getId())?
       └─ 모든 로그에 자동 출력 → 방법 3 (Custom JsonProvider)
       └─ 특정 로그 라인에만 출력 → 방법 2 (StructuredArguments)
       └─ <pattern> 안에서 %tId로 쓰고 싶다 → 방법 4 (Custom Converter)
```

> 방법 1(MDC)이 가장 적은 코드 변경으로 ECS와 동일한 동작을 구현합니다.
> 기존 ThreadLocal 코드가 있다면 `MDC.put("tId", ThreadLocal.get())`으로 브릿징하세요.
