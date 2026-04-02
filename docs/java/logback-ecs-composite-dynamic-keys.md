# LoggingEventCompositeJsonEncoder — ECS 설정 & 동적 키 생성

`LoggingEventCompositeJsonEncoder`에서 ECS(Elastic Common Schema) 필드 구조를 맞추면서
런타임 상황에 따라 JSON 키를 동적으로 생성하는 방법을 설명합니다.

---

## 1. 의존성 추가

```xml
<!-- pom.xml -->
<dependency>
  <groupId>net.logstash.logback</groupId>
  <artifactId>logstash-logback-encoder</artifactId>
  <version>8.0</version>
</dependency>
```

```groovy
// build.gradle
implementation 'net.logstash.logback:logstash-logback-encoder:8.0'
```

---

## 2. ECS 필드 구조로 logback.xml 설정

ECS 스펙 필드명(`@timestamp`, `log.level`, `log.logger`, `error.*`)을
`LoggingEventCompositeJsonEncoder`로 그대로 구현합니다.

```xml
<!-- src/main/resources/logback-spring.xml -->
<configuration>

  <springProperty scope="context" name="APP_NAME"   source="spring.application.name" defaultValue="unknown"/>
  <springProperty scope="context" name="APP_VERSION" source="logging.structured.ecs.service.version" defaultValue=""/>
  <springProperty scope="context" name="APP_ENV"     source="logging.structured.ecs.service.environment" defaultValue="local"/>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
      <providers>

        <!-- ECS: @timestamp -->
        <timestamp>
          <fieldName>@timestamp</fieldName>
          <pattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</pattern>
          <timeZone>UTC</timeZone>
        </timestamp>

        <!-- ECS: log.level / log.logger -->
        <pattern>
          <pattern>
            {
              "log.level": "%level",
              "log.logger": "%logger{36}"
            }
          </pattern>
        </pattern>

        <!-- ECS: process.pid / process.thread.name -->
        <pattern>
          <pattern>
            {
              "process.pid": "${PID:-0}",
              "process.thread.name": "%thread"
            }
          </pattern>
        </pattern>

        <!-- ECS: service.* -->
        <pattern>
          <pattern>
            {
              "service.name":        "${APP_NAME}",
              "service.version":     "${APP_VERSION}",
              "service.environment": "${APP_ENV}"
            }
          </pattern>
        </pattern>

        <!-- ECS: message -->
        <message/>

        <!-- MDC 값 전체 펼치기 (tId 등 동적 필드) -->
        <mdc/>

        <!-- StructuredArguments 키-값 쌍 출력 -->
        <arguments/>

        <!-- ECS: error.* — Throwable 있을 때만 자동 포함 -->
        <nestedField>
          <fieldName>error</fieldName>
          <providers>
            <!-- error.type -->
            <pattern>
              <pattern>{"type": "%ex{short}"}</pattern>
            </pattern>
            <!-- error.message + error.stack_trace -->
            <throwableClassName>
              <useSimpleClassName>false</useSimpleClassName>
            </throwableClassName>
            <stackTrace>
              <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
                <rootCauseFirst>true</rootCauseFirst>
                <maxDepthPerThrowable>30</maxDepthPerThrowable>
                <maxLength>8192</maxLength>
              </throwableConverter>
            </stackTrace>
          </providers>
        </nestedField>

      </providers>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>

</configuration>
```

> `<nestedField>`는 Throwable이 없으면 `error` 블록 전체를 출력하지 않습니다.

---

## 3. 동적 키 생성 방법 3가지

### 방법 A — MDC로 런타임 키 주입

요청마다 달라지는 값(트랜잭션 ID, 사용자 ID 등)을 MDC에 넣으면
`<mdc/>` 프로바이더가 키-값을 JSON에 자동으로 펼칩니다.

```java
MDC.put("tId", "a1b2-c3d4");
MDC.put("userId", "user-99");
log.info("주문 처리 시작");
// → JSON에 "tId": "a1b2-c3d4", "userId": "user-99" 자동 포함
MDC.clear();
```

### 방법 B — StructuredArguments로 호출 지점별 동적 키

`net.logstash.logback.argument.StructuredArguments`를 사용하면
로그 호출 시점에 임의의 키를 지정할 수 있습니다.

```java
import static net.logstash.logback.argument.StructuredArguments.*;

// 단일 키-값
log.info("상품 조회", keyValue("productId", "P-001"));

// 여러 키-값 한 번에
log.info("결제 완료", keyValue("orderId", orderId), keyValue("amount", amount));

// Map 전체를 키-값으로 펼치기
Map<String, Object> ctx = Map.of("step", "validate", "retry", 2);
log.info("처리 단계", entries(ctx));
// → "step": "validate", "retry": 2 로 각각 출력됨
```

출력 예시:

```json
{
  "@timestamp": "2024-03-15T10:23:45.123Z",
  "log.level":  "INFO",
  "message":    "결제 완료",
  "orderId":    "ORD-001",
  "amount":     15000
}
```

### 방법 C — Custom JsonProvider로 완전 동적 키 생성

런타임 객체를 분석해 키 이름 자체를 동적으로 결정해야 할 때 사용합니다.

```java
// src/main/java/com/example/logging/DynamicContextJsonProvider.java
package com.example.logging;

import ch.qos.logback.classic.spi.ILoggingEvent;
import com.fasterxml.jackson.core.JsonGenerator;
import net.logstash.logback.composite.AbstractJsonProvider;

import java.io.IOException;
import java.util.Map;

/**
 * MDC 값 중 접두사가 "ctx."인 항목만 추려서
 * 접두사를 제거한 키 이름으로 JSON에 출력합니다.
 *
 * 예) MDC "ctx.region" → JSON "region": "us-east-1"
 */
public class DynamicContextJsonProvider extends AbstractJsonProvider<ILoggingEvent> {

    private static final String PREFIX = "ctx.";

    @Override
    public void writeTo(JsonGenerator generator, ILoggingEvent event) throws IOException {
        Map<String, String> mdc = event.getMDCPropertyMap();
        if (mdc == null || mdc.isEmpty()) return;

        for (Map.Entry<String, String> entry : mdc.entrySet()) {
            String key = entry.getKey();
            if (key.startsWith(PREFIX)) {
                // "ctx.region" → "region"
                generator.writeStringField(key.substring(PREFIX.length()), entry.getValue());
            }
        }
    }
}
```

`logback-spring.xml`에 등록:

```xml
<providers>
  <!-- ... 다른 프로바이더 ... -->

  <!-- 동적 키 생성 커스텀 프로바이더 -->
  <provider class="com.example.logging.DynamicContextJsonProvider"/>
</providers>
```

사용 예:

```java
MDC.put("ctx.region",  "us-east-1");
MDC.put("ctx.cluster", "prod-k8s-01");
MDC.put("tId",         "a1b2-c3d4");   // ctx. 접두사 없음 → 기본 <mdc/>로 출력

log.info("파드 스케줄링 시작");
// → "region": "us-east-1", "cluster": "prod-k8s-01", "tId": "a1b2-c3d4"

MDC.clear();
```

---

## 4. 전체 프로젝트 예제

### 프로젝트 구조

```
src/main/
├─ java/com/example/
│   ├─ logging/
│   │   └─ DynamicContextJsonProvider.java   ← 커스텀 프로바이더
│   ├─ filter/
│   │   └─ RequestContextFilter.java         ← MDC 주입
│   ├─ service/
│   │   └─ OrderService.java                 ← 비즈니스 로직
│   └─ controller/
│       └─ OrderController.java
└─ resources/
    ├─ application.yml
    └─ logback-spring.xml
```

### application.yml

```yaml
spring:
  application:
    name: order-service

logging:
  structured:
    ecs:
      service:
        version: "2.1.0"
        environment: "production"
```

### RequestContextFilter.java

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

        HttpServletRequest http = (HttpServletRequest) req;

        // 고정 동적 키: 매 요청마다 값이 달라짐
        String tId = http.getHeader("X-Transaction-Id");
        if (tId == null || tId.isBlank()) tId = UUID.randomUUID().toString();
        MDC.put("tId", tId);

        // ctx. 접두사 키: DynamicContextJsonProvider가 처리
        String region = http.getHeader("X-Region");
        if (region != null) MDC.put("ctx.region", region);

        try {
            chain.doFilter(req, res);
        } finally {
            MDC.clear();
        }
    }
}
```

### OrderService.java

```java
package com.example.service;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import static net.logstash.logback.argument.StructuredArguments.keyValue;
import static net.logstash.logback.argument.StructuredArguments.entries;

import java.util.Map;

@Slf4j
@Service
public class OrderService {

    public void placeOrder(String orderId, int amount, String itemCode) {

        // StructuredArguments: 호출 시점에 키를 동적으로 지정
        log.info("주문 접수", keyValue("orderId", orderId), keyValue("amount", amount));

        try {
            validate(amount);
            process(orderId, itemCode);

            // Map 전체를 동적 키로 펼치기
            Map<String, Object> result = Map.of(
                "orderId",  orderId,
                "itemCode", itemCode,
                "status",   "COMPLETED"
            );
            log.info("주문 완료", entries(result));

        } catch (IllegalArgumentException e) {
            // Throwable 전달 → error.* 블록 자동 생성
            log.error("주문 유효성 오류 orderId={}", orderId, e);
            throw e;
        } catch (Exception e) {
            log.error("주문 처리 실패 orderId={}", orderId, e);
            throw new RuntimeException("주문 오류", e);
        }
    }

    private void validate(int amount) {
        if (amount <= 0) throw new IllegalArgumentException("금액 오류: " + amount);
    }

    private void process(String orderId, String itemCode) {
        // 처리 로직 ...
    }
}
```

### OrderController.java

```java
package com.example.controller;

import com.example.service.OrderService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
@RequiredArgsConstructor
@RequestMapping("/orders")
public class OrderController {

    private final OrderService orderService;

    @PostMapping
    public String order(@RequestParam String orderId,
                        @RequestParam int amount,
                        @RequestParam String itemCode) {
        log.info("주문 API 진입 orderId={}", orderId);
        orderService.placeOrder(orderId, amount, itemCode);
        return "OK";
    }
}
```

---

## 5. 출력 예시

### 정상 주문 (INFO)

```json
{
  "@timestamp":          "2024-03-15T10:23:45.123Z",
  "log.level":           "INFO",
  "log.logger":          "c.e.service.OrderService",
  "process.pid":         "12345",
  "process.thread.name": "http-nio-8080-exec-3",
  "service.name":        "order-service",
  "service.version":     "2.1.0",
  "service.environment": "production",
  "message":             "주문 완료",
  "tId":                 "a1b2-c3d4-e5f6",
  "region":              "us-east-1",
  "orderId":             "ORD-001",
  "itemCode":            "ITEM-42",
  "status":              "COMPLETED"
}
```

> - `tId`: MDC → `<mdc/>` 프로바이더가 그대로 출력
> - `region`: MDC `ctx.region` → `DynamicContextJsonProvider`가 접두사 제거 후 출력
> - `orderId`, `itemCode`, `status`: `entries(result)` → `<arguments/>` 프로바이더가 출력

### 예외 발생 (ERROR + Throwable)

```json
{
  "@timestamp":          "2024-03-15T10:23:45.456Z",
  "log.level":           "ERROR",
  "log.logger":          "c.e.service.OrderService",
  "process.pid":         "12345",
  "process.thread.name": "http-nio-8080-exec-3",
  "service.name":        "order-service",
  "service.version":     "2.1.0",
  "service.environment": "production",
  "message":             "주문 유효성 오류 orderId=ORD-001",
  "tId":                 "a1b2-c3d4-e5f6",
  "region":              "us-east-1",
  "error": {
    "type":        "java.lang.IllegalArgumentException",
    "stack_trace": "java.lang.IllegalArgumentException: 금액 오류: 0\n\tat com.example.service.OrderService.validate(OrderService.java:38)\n\t..."
  }
}
```

> `error` 블록은 Throwable을 `log.error("...", e)`로 전달했을 때만 생성됩니다.

---

## 6. 동적 키 방법 비교

| 방법 | 키 이름 결정 시점 | 사용 위치 | 대표 사용처 |
|------|-----------------|-----------|-------------|
| `MDC.put(key, val)` + `<mdc/>` | 런타임 (필터/서비스) | 스레드 전체 | tId, 세션 ID 등 요청 공통 값 |
| `StructuredArguments.keyValue()` | 로그 호출 시점 | 특정 로그 라인 | 주문 ID, 금액 등 개별 이벤트 값 |
| `StructuredArguments.entries()` | 로그 호출 시점 | 특정 로그 라인 | 결과 Map 전체를 필드로 펼칠 때 |
| `Custom JsonProvider` | 런타임 (MDC 분석) | 인코더 전역 | 접두사 기반 키 변환, 외부 컨텍스트 주입 |

---

## 7. 같이 보기

- [ECS vs LoggingEventCompositeJsonEncoder 비교](../springboot/ecs-vs-logback-json.md)
- [Logback 코드 내부 값을 JSON으로 출력](../springboot/logback-internal-values.md)
- [logstash-logback-encoder Provider 필드 정리](../springboot/logback-providers.md)
