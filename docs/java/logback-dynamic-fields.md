# Logback 동적 필드 주입 — MDC · Arguments · LogstashMarkers · Custom Provider

`LoggingEventCompositeJsonEncoder`에서 런타임 값을 JSON 필드로 출력하는 4가지 방법을
동작 원리·흔한 실수·실전 예제 코드와 함께 정리합니다.

---

## 공통 의존성

```xml
<!-- pom.xml -->
<dependency>
  <groupId>net.logstash.logback</groupId>
  <artifactId>logstash-logback-encoder</artifactId>
  <version>8.0</version>
</dependency>
```

---

## 공통 logback-spring.xml

아래 설정을 기준으로 각 방법의 예제를 실행합니다.

```xml
<!-- src/main/resources/logback-spring.xml -->
<configuration>

  <springProperty scope="context" name="APP_NAME" source="spring.application.name" defaultValue="app"/>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">

      <jsonGeneratorDecorator
        class="net.logstash.logback.decorate.PrettyPrintingJsonGeneratorDecorator"/>

      <providers>
        <timestamp>
          <fieldName>@timestamp</fieldName>
          <pattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</pattern>
          <timeZone>UTC</timeZone>
        </timestamp>
        <pattern>
          <pattern>{ "level": "%level", "logger": "%logger{36}", "app": "${APP_NAME}" }</pattern>
        </pattern>
        <message/>

        <!-- 방법 1: MDC 전체 펼치기 -->
        <mdc/>

        <!-- 방법 2: StructuredArguments -->
        <arguments/>

        <!-- 방법 3: LogstashMarkers — arguments 프로바이더가 Marker도 처리 -->

        <!-- 방법 4: Custom JsonProvider (아래 섹션에서 등록) -->

        <stackTrace>
          <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
            <rootCauseFirst>true</rootCauseFirst>
            <maxDepthPerThrowable>20</maxDepthPerThrowable>
          </throwableConverter>
        </stackTrace>
      </providers>

    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>

</configuration>
```

---

## 방법 1. MDC

### 동작 원리

`MDC`(Mapped Diagnostic Context)는 스레드에 바인딩된 `Map<String, String>` 저장소입니다.
`<mdc/>` 프로바이더는 로그 이벤트 발생 시점의 MDC 전체를 JSON 최상위 필드로 펼칩니다.

```
MDC.put("tId", "a1b2") ──► 스레드 로컬 맵에 저장
log.info("...")         ──► ILoggingEvent 생성 시 getMDCPropertyMap() 스냅샷
<mdc/>                  ──► 스냅샷을 JSON 필드로 펼침
MDC.clear()             ──► 스레드 풀 반환 전 반드시 정리
```

### 안 되는 흔한 이유 5가지

| 증상 | 원인 | 해결 |
|------|------|------|
| JSON에 MDC 키가 없음 | `logback.xml`에 `<mdc/>` 누락 | `<providers>`에 `<mdc/>` 추가 |
| 일부 요청만 출력됨 | `MDC.clear()`를 안 해서 이전 값이 오염 | `finally` 블록에서 반드시 `MDC.clear()` |
| 비동기 스레드에서 사라짐 | `@Async`, `CompletableFuture` 등 별도 스레드는 MDC를 공유하지 않음 | 자식 스레드에 수동 복사 (아래 예제 참고) |
| Virtual Thread에서 사라짐 | Java 21 Virtual Thread는 부모 MDC를 상속하지 않음 | `MDC.getCopyOfContextMap()`으로 수동 복사 |
| `AsyncAppender` 사용 시 사라짐 | 기본 설정에서 MDC가 큐에서 손실됨 | `<includeCallerData>true</includeCallerData>` 추가 (실제로는 MDC 전달에는 `LogstashEncoder` 자체 처리 필요) |

### 올바른 사용 패턴

#### Filter에서 put/clear

```java
package com.example.filter;

import jakarta.servlet.*;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.MDC;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.util.UUID;

@Component
@Order(1)
public class RequestContextFilter implements Filter {

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {

        String tId = ((HttpServletRequest) req).getHeader("X-Transaction-Id");
        if (tId == null || tId.isBlank()) tId = UUID.randomUUID().toString();

        MDC.put("tId", tId);
        MDC.put("clientIp", req.getRemoteAddr());

        try {
            chain.doFilter(req, res);
        } finally {
            MDC.clear(); // ★ 스레드 풀 반환 전 반드시 정리
        }
    }
}
```

#### 비동기 처리 — MDC 수동 복사

`@Async` 또는 `CompletableFuture`로 별도 스레드를 쓸 때는 MDC를 직접 전달해야 합니다.

```java
import org.slf4j.MDC;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

@Service
public class AsyncOrderService {

    public CompletableFuture<Void> processAsync(String orderId) {
        // 호출 시점의 MDC 스냅샷을 캡처
        Map<String, String> mdcSnapshot = MDC.getCopyOfContextMap();

        return CompletableFuture.runAsync(() -> {
            // 자식 스레드에 MDC 복원
            if (mdcSnapshot != null) MDC.setContextMap(mdcSnapshot);
            try {
                log.info("비동기 주문 처리 orderId={}", orderId);
                // 처리 로직 ...
            } finally {
                MDC.clear(); // 자식 스레드도 정리
            }
        });
    }
}
```

#### MDC Propagation — TaskDecorator로 자동화

매번 수동 복사하는 대신 `TaskDecorator`로 한 번에 처리합니다.

```java
package com.example.config;

import org.slf4j.MDC;
import org.springframework.core.task.TaskDecorator;
import java.util.Map;

public class MdcTaskDecorator implements TaskDecorator {

    @Override
    public Runnable decorate(Runnable runnable) {
        // 제출 시점(부모 스레드)의 MDC 캡처
        Map<String, String> mdcSnapshot = MDC.getCopyOfContextMap();

        return () -> {
            if (mdcSnapshot != null) MDC.setContextMap(mdcSnapshot);
            try {
                runnable.run();
            } finally {
                MDC.clear();
            }
        };
    }
}
```

```java
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {

    @Override
    public Executor getAsyncExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(4);
        executor.setMaxPoolSize(8);
        executor.setTaskDecorator(new MdcTaskDecorator()); // ★ 등록
        executor.initialize();
        return executor;
    }
}
```

### 특정 키만 포함/제외

```xml
<!-- 특정 키만 출력 -->
<mdc>
  <includeMdcKeyName>tId</includeMdcKeyName>
  <includeMdcKeyName>clientIp</includeMdcKeyName>
</mdc>

<!-- 특정 키 제외 -->
<mdc>
  <excludeMdcKeyName>password</excludeMdcKeyName>
</mdc>

<!-- 하위 오브젝트로 중첩 -->
<mdc>
  <fieldName>context</fieldName>
</mdc>
<!-- 출력: "context": { "tId": "a1b2", "clientIp": "10.0.0.1" } -->
```

### 출력 예시

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "logger" : "c.e.service.OrderService",
  "app" : "order-service",
  "message" : "주문 접수",
  "tId" : "a1b2-c3d4-e5f6",
  "clientIp" : "10.0.0.1"
}
```

---

## 방법 2. StructuredArguments

### 동작 원리

`log.info("msg", arg1, arg2)` 호출 시 인자를 `StructuredArgument` 타입으로 넘기면
`<arguments/>` 프로바이더가 JSON 필드로 출력합니다.
MDC와 달리 **해당 로그 라인에만** 필드가 붙습니다.

```
log.info("주문 완료", keyValue("orderId", "ORD-001"))
          ↓
ILoggingEvent.getArgumentArray() → [ StructuredArgument ]
          ↓
<arguments/> → "orderId": "ORD-001" 출력
```

### 전체 API 예제

```java
package com.example.service;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Map;

import static net.logstash.logback.argument.StructuredArguments.*;

@Slf4j
@Service
public class OrderService {

    public void demonstrate() {

        // 1. keyValue — 단일 키-값
        log.info("단일 필드", keyValue("orderId", "ORD-001"));
        // → "orderId": "ORD-001"

        // 2. kv — keyValue 축약형 (완전히 동일)
        log.info("축약형", kv("orderId", "ORD-001"));

        // 3. value — 메시지에는 값만 치환, JSON에는 키-값으로 출력
        log.info("메시지에도 표시: {}", value("orderId", "ORD-001"));
        // message → "메시지에도 표시: ORD-001"
        // JSON   → "orderId": "ORD-001"

        // 4. entries — Map 전체를 최상위 필드로 펼치기
        Map<String, Object> result = Map.of(
            "orderId", "ORD-001",
            "amount", 15000,
            "status", "COMPLETED"
        );
        log.info("주문 완료", entries(result));
        // → "orderId": "ORD-001", "amount": 15000, "status": "COMPLETED"

        // 5. fields — POJO 필드를 최상위 필드로 펼치기
        OrderResult order = new OrderResult("ORD-001", 15000);
        log.info("주문 완료", fields(order));
        // → "orderId": "ORD-001", "amount": 15000

        // 6. array — 배열 필드
        log.info("태그 목록", array("tags", "vip", "fast-delivery", "gift"));
        // → "tags": ["vip", "fast-delivery", "gift"]

        // 7. raw — 이미 직렬화된 JSON 문자열을 그대로 삽입
        log.info("원시 JSON", raw("payload", "{\"key\":\"value\"}"));
        // → "payload": {"key": "value"}  (문자열이 아닌 객체로 삽입)

        // 여러 인자 동시 사용
        log.info("복합 필드",
            kv("orderId", "ORD-001"),
            kv("amount", 15000),
            array("items", "ITEM-A", "ITEM-B")
        );
    }

    // fields() 사용을 위한 POJO (getter 필요)
    static class OrderResult {
        private final String orderId;
        private final int amount;
        OrderResult(String orderId, int amount) {
            this.orderId = orderId;
            this.amount = amount;
        }
        public String getOrderId() { return orderId; }
        public int getAmount()     { return amount; }
    }
}
```

### 안 되는 흔한 이유

| 증상 | 원인 | 해결 |
|------|------|------|
| JSON에 필드가 없음 | `logback.xml`에 `<arguments/>` 누락 | `<providers>`에 `<arguments/>` 추가 |
| `{}`가 메시지에 그대로 출력됨 | `keyValue()`가 아닌 일반 객체를 인자로 전달 | `keyValue("key", val)` 사용 |
| 숫자가 문자열로 출력됨 | `keyValue("amount", String.valueOf(15000))` | `keyValue("amount", 15000)` — 타입 그대로 전달 |

### 출력 예시

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "logger" : "c.e.service.OrderService",
  "app" : "order-service",
  "message" : "주문 완료",
  "tId" : "a1b2-c3d4",
  "orderId" : "ORD-001",
  "amount" : 15000,
  "status" : "COMPLETED"
}
```

---

## 방법 3. LogstashMarkers

### 동작 원리

`Marker`를 첫 번째 인자로 넘기는 SLF4J 패턴을 사용합니다.
`LogstashMarkers`는 Marker에 JSON 필드 정보를 담고,
`<arguments/>` 프로바이더(또는 내부적으로 Marker 처리)가 이를 JSON으로 출력합니다.

StructuredArguments와의 차이: **Marker는 MDC를 건드리지 않으면서
로그 호출부에서 구조화된 컨텍스트를 선언적으로 전달**할 수 있습니다.
여러 Marker를 `and()`로 체이닝할 수 있고, 필터링(Marker 기반 라우팅)에도 사용 가능합니다.

### 전체 API 예제

```java
package com.example.service;

import lombok.extern.slf4j.Slf4j;
import net.logstash.logback.marker.LogstashMarker;
import org.slf4j.Marker;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Map;

import static net.logstash.logback.marker.Markers.*;

@Slf4j
@Service
public class MarkerDemoService {

    public void demonstrate() {

        // 1. append — 단일 키-값 (keyValue와 동일한 역할)
        log.info(append("orderId", "ORD-001"), "주문 접수");
        // → "orderId": "ORD-001"

        // 2. appendEntries — Map 전체를 최상위 필드로 펼치기
        Map<String, Object> ctx = Map.of("orderId", "ORD-001", "amount", 15000);
        log.info(appendEntries(ctx), "주문 완료");
        // → "orderId": "ORD-001", "amount": 15000

        // 3. appendArray — 배열 필드
        log.info(appendArray("tags", "vip", "gift"), "태그 정보");
        // → "tags": ["vip", "gift"]

        // 4. appendRaw — 직렬화된 JSON 문자열을 오브젝트로 삽입
        log.info(appendRaw("payload", "{\"key\":\"value\"}"), "원시 데이터");
        // → "payload": {"key": "value"}

        // 5. and() — 여러 Marker 체이닝
        LogstashMarker marker = append("orderId", "ORD-001")
            .and(append("amount", 15000))
            .and(appendArray("items", "ITEM-A", "ITEM-B"));

        log.info(marker, "복합 Marker 예제");
        // → "orderId": "ORD-001", "amount": 15000, "items": ["ITEM-A", "ITEM-B"]

        // 6. Marker + StructuredArguments 혼합
        log.info(
            append("source", "payment-api"),
            "결제 요청 처리",
            kv("paymentId", "PAY-999")   // import static StructuredArguments.*
        );
        // → "source": "payment-api", "paymentId": "PAY-999"
    }
}
```

> `import static net.logstash.logback.marker.Markers.*` 를 선언하면
> `append`, `appendEntries`, `appendArray`, `appendRaw` 를 바로 사용할 수 있습니다.

### StructuredArguments vs LogstashMarkers

| 항목 | StructuredArguments | LogstashMarkers |
|------|---------------------|-----------------|
| 전달 위치 | 가변 인자 (`arg1, arg2, ...`) | 첫 번째 인자 (`Marker`) |
| 체이닝 | 인자 나열 | `.and()` 체이닝 |
| Marker 기반 필터링 | 불가 | 가능 |
| 사용 편의성 | 더 간결 | Marker 재사용에 유리 |
| `entries(Map)` 상당 | `entries(map)` | `appendEntries(map)` |

### 안 되는 흔한 이유

| 증상 | 원인 | 해결 |
|------|------|------|
| Marker 필드가 출력 안 됨 | `<arguments/>` 누락 | `<providers>`에 `<arguments/>` 추가 |
| Marker가 첫 인자가 아님 | `log.info("msg", marker)` 순서 오류 | **반드시** `log.info(marker, "msg")` — Marker가 첫 번째 |
| 체이닝이 반영 안 됨 | `append(...).and(...)` 반환값 미사용 | 반환된 `LogstashMarker`를 변수에 저장 후 전달 |

### 출력 예시

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "logger" : "c.e.service.MarkerDemoService",
  "app" : "order-service",
  "message" : "복합 Marker 예제",
  "orderId" : "ORD-001",
  "amount" : 15000,
  "items" : [ "ITEM-A", "ITEM-B" ]
}
```

---

## 방법 4. Custom JsonProvider

### 동작 원리

`AbstractJsonProvider<ILoggingEvent>`를 구현해 `writeTo()` 메서드 안에서
`JsonGenerator`로 직접 필드를 씁니다.
모든 로그 이벤트에 전역으로 자동 적용되며, ThreadLocal·외부 컨텍스트 등
MDC/Marker로 전달하기 어려운 값을 주입할 때 사용합니다.

### 예제 1 — ThreadLocal 값 자동 주입

```java
package com.example.logging;

import ch.qos.logback.classic.spi.ILoggingEvent;
import com.fasterxml.jackson.core.JsonGenerator;
import net.logstash.logback.composite.AbstractJsonProvider;

import java.io.IOException;

/**
 * 기존 코드의 ThreadLocal에서 tId를 읽어 모든 로그에 자동으로 주입합니다.
 * 값이 없으면 필드 자체를 출력하지 않습니다.
 */
public class TransactionIdJsonProvider extends AbstractJsonProvider<ILoggingEvent> {

    private String fieldName = "tId"; // logback.xml에서 <fieldName>으로 오버라이드 가능

    @Override
    public void writeTo(JsonGenerator generator, ILoggingEvent event) throws IOException {
        String tId = TransactionContext.get(); // 기존 ThreadLocal 조회
        if (tId != null && !tId.isBlank()) {
            generator.writeStringField(fieldName, tId);
        }
        // null이면 필드 자체를 쓰지 않음 → 동적 출력
    }

    public void setFieldName(String fieldName) { this.fieldName = fieldName; }
}
```

```java
package com.example.logging;

/** 기존 코드의 ThreadLocal 컨텍스트 (예시) */
public class TransactionContext {
    private static final ThreadLocal<String> TID = new ThreadLocal<>();
    public static void set(String tId)  { TID.set(tId); }
    public static String get()          { return TID.get(); }
    public static void clear()          { TID.remove(); }
}
```

### 예제 2 — MDC 키 변환 (접두사 제거)

```java
package com.example.logging;

import ch.qos.logback.classic.spi.ILoggingEvent;
import com.fasterxml.jackson.core.JsonGenerator;
import net.logstash.logback.composite.AbstractJsonProvider;

import java.io.IOException;
import java.util.Map;

/**
 * MDC 키 중 "ctx." 접두사가 붙은 항목만 추출해
 * 접두사를 제거한 이름으로 JSON 필드를 씁니다.
 *
 * MDC.put("ctx.region", "us-east-1") → JSON "region": "us-east-1"
 */
public class ContextPrefixJsonProvider extends AbstractJsonProvider<ILoggingEvent> {

    private String prefix = "ctx.";

    @Override
    public void writeTo(JsonGenerator generator, ILoggingEvent event) throws IOException {
        Map<String, String> mdc = event.getMDCPropertyMap();
        if (mdc == null || mdc.isEmpty()) return;

        for (Map.Entry<String, String> entry : mdc.entrySet()) {
            if (entry.getKey().startsWith(prefix)) {
                String shortKey = entry.getKey().substring(prefix.length());
                generator.writeStringField(shortKey, entry.getValue());
            }
        }
    }

    public void setPrefix(String prefix) { this.prefix = prefix; }
}
```

### 예제 3 — 중첩 오브젝트 필드 생성

```java
package com.example.logging;

import ch.qos.logback.classic.spi.ILoggingEvent;
import com.fasterxml.jackson.core.JsonGenerator;
import net.logstash.logback.composite.AbstractJsonProvider;

import java.io.IOException;

/**
 * 모든 로그에 "host" 오브젝트 필드를 추가합니다.
 * { "host": { "name": "pod-abc123", "ip": "10.0.0.5" } }
 */
public class HostInfoJsonProvider extends AbstractJsonProvider<ILoggingEvent> {

    @Override
    public void writeTo(JsonGenerator generator, ILoggingEvent event) throws IOException {
        String podName = System.getenv("POD_NAME");
        String podIp   = System.getenv("POD_IP");
        if (podName == null && podIp == null) return;

        generator.writeObjectFieldStart("host");   // "host": {
        if (podName != null) generator.writeStringField("name", podName);
        if (podIp   != null) generator.writeStringField("ip",   podIp);
        generator.writeEndObject();                // }
    }
}
```

### logback-spring.xml에 Custom Provider 등록

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">

  <jsonGeneratorDecorator
    class="net.logstash.logback.decorate.PrettyPrintingJsonGeneratorDecorator"/>

  <providers>
    <timestamp><fieldName>@timestamp</fieldName></timestamp>
    <pattern>
      <pattern>{ "level": "%level", "logger": "%logger{36}" }</pattern>
    </pattern>
    <message/>
    <mdc/>
    <arguments/>

    <!-- Custom Provider 1: ThreadLocal → tId 자동 주입 -->
    <provider class="com.example.logging.TransactionIdJsonProvider">
      <fieldName>tId</fieldName>
    </provider>

    <!-- Custom Provider 2: ctx.* MDC 키 접두사 제거 후 출력 -->
    <provider class="com.example.logging.ContextPrefixJsonProvider">
      <prefix>ctx.</prefix>
    </provider>

    <!-- Custom Provider 3: 중첩 host 오브젝트 -->
    <provider class="com.example.logging.HostInfoJsonProvider"/>

    <stackTrace/>
  </providers>
</encoder>
```

### 출력 예시

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "logger" : "c.e.service.OrderService",
  "message" : "주문 접수",
  "tId" : "a1b2-c3d4",
  "region" : "us-east-1",
  "host" : {
    "name" : "order-pod-abc123",
    "ip" : "10.0.0.5"
  }
}
```

---

## 통합 예제 — 4가지 방법 함께 사용

### 전체 프로젝트 구조

```
src/main/
├─ java/com/example/
│   ├─ config/
│   │   └─ AsyncConfig.java              ← MDC TaskDecorator 설정
│   ├─ filter/
│   │   └─ RequestContextFilter.java     ← MDC put/clear
│   ├─ logging/
│   │   ├─ TransactionContext.java       ← ThreadLocal 컨텍스트
│   │   ├─ TransactionIdJsonProvider.java
│   │   ├─ ContextPrefixJsonProvider.java
│   │   └─ HostInfoJsonProvider.java
│   └─ service/
│       └─ OrderService.java             ← 4가지 방법 사용
└─ resources/
    ├─ application.yml
    └─ logback-spring.xml
```

### OrderService.java — 4가지 방법 통합

```java
package com.example.service;

import lombok.extern.slf4j.Slf4j;
import org.slf4j.MDC;
import org.springframework.stereotype.Service;

import java.util.Map;

import static net.logstash.logback.argument.StructuredArguments.*;
import static net.logstash.logback.marker.Markers.*;

@Slf4j
@Service
public class OrderService {

    public void placeOrder(String orderId, int amount, String region) {

        // ── 방법 1. MDC — 요청 단위 공통값 (Filter에서 이미 tId 설정됨) ──
        MDC.put("ctx.region", region);   // ContextPrefixJsonProvider가 "region"으로 출력

        // 방법 2. StructuredArguments — 이 로그 라인에만 붙는 필드
        log.info("주문 접수",
            kv("orderId", orderId),
            kv("amount", amount)
        );

        // 방법 3. LogstashMarkers — Marker 체이닝으로 복합 컨텍스트 전달
        log.info(
            append("step", "validation")
                .and(append("orderId", orderId)),
            "주문 유효성 검사"
        );

        // entries로 Map 전체 펼치기 (방법 2)
        Map<String, Object> result = Map.of(
            "orderId", orderId,
            "amount",  amount,
            "status",  "COMPLETED"
        );
        log.info("주문 완료", entries(result));

        // 방법 4. Custom Provider는 모든 로그에 자동 적용
        // → tId (TransactionIdJsonProvider)
        // → region (ContextPrefixJsonProvider — MDC ctx.region)
        // → host.name, host.ip (HostInfoJsonProvider)

        MDC.remove("ctx.region"); // 요청 범위 밖 키는 개별 정리
    }
}
```

---

## 방법 선택 기준

```
모든 로그에 자동으로 붙어야 하는 값?
  ├─ 요청 단위 (HTTP 스레드 범위)     → 방법 1: MDC  (Filter에서 put/clear)
  ├─ 시스템/인프라 값 (Pod, IP 등)    → 방법 4: Custom JsonProvider
  └─ 기존 ThreadLocal 코드가 있음     → 방법 4: Custom JsonProvider (ThreadLocal 직접 읽기)

특정 로그 라인에만 붙는 값?
  ├─ 인자 나열이 더 간결함            → 방법 2: StructuredArguments (kv, entries)
  └─ Marker 재사용 / 라우팅 필터 필요 → 방법 3: LogstashMarkers (append, appendEntries)

비동기 스레드에서 MDC가 사라진다?
  └─ TaskDecorator에 MdcTaskDecorator 등록 → MDC 스냅샷 자동 복사
```

---

## 같이 보기

- [CompositeJsonEncoder ECS 설정 & 동적 키 생성](logback-ecs-composite-dynamic-keys.md)
- [PrettyPrintingDecorator + pattern 커스텀 필드](logback-pretty-print-pattern.md)
- [logstash-logback-encoder Provider 필드 정리](../springboot/logback-providers.md)
- [Logback 코드 내부 값을 JSON으로 출력](../springboot/logback-internal-values.md)
