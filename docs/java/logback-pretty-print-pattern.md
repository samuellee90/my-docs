# PrettyPrintingJsonGeneratorDecorator + pattern 커스텀 필드 정의

`LoggingEventCompositeJsonEncoder`에 `PrettyPrintingJsonGeneratorDecorator`를 적용해
들여쓰기된 JSON을 출력하면서, `<pattern>`으로 원하는 필드를 자유롭게 정의하는 방법을 설명합니다.

---

## 1. PrettyPrintingJsonGeneratorDecorator란?

`LoggingEventCompositeJsonEncoder`는 기본적으로 JSON을 한 줄로 출력합니다.

```json
{"@timestamp":"2024-03-15T10:23:45.123Z","level":"INFO","message":"주문 접수","orderId":"ORD-001"}
```

`PrettyPrintingJsonGeneratorDecorator`를 추가하면 `JsonGenerator`를 래핑해
Jackson의 `DefaultPrettyPrinter`가 적용된 들여쓰기 출력으로 바뀝니다.

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "message" : "주문 접수",
  "orderId" : "ORD-001"
}
```

> **운영 환경에서는 비권장** — 로그 한 줄이 여러 줄이 되면 Fluentd·Filebeat 등
> 로그 수집기의 멀티라인 파싱 설정이 필요합니다.
> 개발/디버그 환경에서만 사용하는 것을 권장합니다.

---

## 2. 의존성

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

## 3. 기본 설정

`<encoder>` 안에 `<jsonGeneratorDecorator>` 태그로 선언합니다.

```xml
<!-- src/main/resources/logback-spring.xml -->
<configuration>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">

      <!-- PrettyPrinting 적용 -->
      <jsonGeneratorDecorator
        class="net.logstash.logback.decorate.PrettyPrintingJsonGeneratorDecorator"/>

      <providers>
        <timestamp>
          <fieldName>@timestamp</fieldName>
          <pattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</pattern>
          <timeZone>UTC</timeZone>
        </timestamp>
        <logLevel><fieldName>level</fieldName></logLevel>
        <message/>
        <mdc/>
        <stackTrace/>
      </providers>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>

</configuration>
```

---

## 4. `<pattern>`으로 원하는 필드 직접 정의

`<pattern>` 프로바이더 안에 JSON 리터럴을 쓰고, Logback 패턴 문법(`%level`, `%logger` 등)과
시스템 프로퍼티(`${VAR}`)를 혼합할 수 있습니다.

### 4-1. 정적 필드 + Logback 패턴 혼합

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">

  <jsonGeneratorDecorator
    class="net.logstash.logback.decorate.PrettyPrintingJsonGeneratorDecorator"/>

  <providers>

    <!-- 원하는 필드를 <pattern>으로 자유 정의 -->
    <pattern>
      <pattern>
        {
          "@timestamp"  : "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z',UTC}",
          "level"       : "%level",
          "logger"      : "%logger{36}",
          "thread"      : "%thread",
          "pid"         : "${PID:-0}",
          "app"         : "${spring.application.name:-unknown}",
          "env"         : "${spring.profiles.active:-local}"
        }
      </pattern>
    </pattern>

    <!-- message, MDC, stackTrace는 별도 프로바이더로 -->
    <message/>
    <mdc/>
    <stackTrace>
      <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
        <rootCauseFirst>true</rootCauseFirst>
        <maxDepthPerThrowable>20</maxDepthPerThrowable>
      </throwableConverter>
    </stackTrace>

  </providers>
</encoder>
```

출력:

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "logger" : "c.e.service.OrderService",
  "thread" : "http-nio-8080-exec-3",
  "pid" : "12345",
  "app" : "order-service",
  "env" : "production",
  "message" : "주문 접수",
  "tId" : "a1b2-c3d4"
}
```

### 4-2. 중첩 객체 필드 정의

`<pattern>` 안에 중첩 JSON을 그대로 쓸 수 있습니다.

```xml
<pattern>
  <pattern>
    {
      "@timestamp" : "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z',UTC}",
      "level"      : "%level",
      "service" : {
        "name"    : "${spring.application.name:-unknown}",
        "env"     : "${spring.profiles.active:-local}",
        "version" : "${APP_VERSION:-}"
      },
      "process" : {
        "pid"    : "${PID:-0}",
        "thread" : "%thread"
      },
      "log" : {
        "logger" : "%logger{36}"
      }
    }
  </pattern>
</pattern>
```

출력:

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "service" : {
    "name" : "order-service",
    "env" : "production",
    "version" : "2.1.0"
  },
  "process" : {
    "pid" : "12345",
    "thread" : "http-nio-8080-exec-3"
  },
  "log" : {
    "logger" : "c.e.service.OrderService"
  },
  "message" : "주문 접수"
}
```

### 4-3. 조건부 필드 — `%replace`로 빈 값 제거

값이 없을 때 필드를 `null`로 두기보단 빈 문자열로 치환해 수집기 파싱 오류를 방지합니다.

```xml
<pattern>
  <pattern>
    {
      "@timestamp" : "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z',UTC}",
      "level"      : "%level",
      "traceId"    : "%replace(%X{traceId}){'\\s*', ''}",
      "spanId"     : "%replace(%X{spanId}){'\\s*', ''}"
    }
  </pattern>
</pattern>
```

> `%X{key}`는 MDC 값을 패턴 안에서 참조합니다.
> 값이 없으면 빈 문자열(`""`)로 출력됩니다.

---

## 5. 환경별 분기 — 개발만 PrettyPrint

`logback-spring.xml`의 `<springProfile>`로 로컬/개발 환경에서만 PrettyPrint를 적용합니다.

```xml
<configuration>

  <springProperty scope="context" name="APP_NAME" source="spring.application.name" defaultValue="app"/>

  <!-- 로컬/개발: PrettyPrint JSON -->
  <springProfile name="local,dev">
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
      <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">

        <jsonGeneratorDecorator
          class="net.logstash.logback.decorate.PrettyPrintingJsonGeneratorDecorator"/>

        <providers>
          <pattern>
            <pattern>
              {
                "@timestamp" : "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z',UTC}",
                "level"      : "%level",
                "logger"     : "%logger{36}",
                "thread"     : "%thread",
                "app"        : "${APP_NAME}"
              }
            </pattern>
          </pattern>
          <message/>
          <mdc/>
          <stackTrace/>
        </providers>
      </encoder>
    </appender>
  </springProfile>

  <!-- 운영: 한 줄 JSON (PrettyPrint 없음) -->
  <springProfile name="production,staging">
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
      <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
        <providers>
          <pattern>
            <pattern>
              {
                "@timestamp" : "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z',UTC}",
                "level"      : "%level",
                "logger"     : "%logger{36}",
                "thread"     : "%thread",
                "app"        : "${APP_NAME}"
              }
            </pattern>
          </pattern>
          <message/>
          <mdc/>
          <stackTrace/>
        </providers>
      </encoder>
    </appender>
  </springProfile>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>

</configuration>
```

---

## 6. 전체 예제

### 프로젝트 구조

```
src/main/
├─ java/com/example/
│   ├─ filter/
│   │   └─ RequestContextFilter.java
│   └─ service/
│       └─ OrderService.java
└─ resources/
    ├─ application.yml
    └─ logback-spring.xml
```

### application.yml

```yaml
spring:
  application:
    name: order-service
  profiles:
    active: local

APP_VERSION: "2.1.0"
```

### logback-spring.xml (전체)

```xml
<configuration>

  <springProperty scope="context" name="APP_NAME"    source="spring.application.name" defaultValue="app"/>
  <springProperty scope="context" name="APP_VERSION" source="APP_VERSION"             defaultValue=""/>
  <springProperty scope="context" name="APP_ENV"     source="spring.profiles.active"  defaultValue="local"/>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">

      <!-- 개발용 PrettyPrint (운영에서는 이 줄 제거) -->
      <jsonGeneratorDecorator
        class="net.logstash.logback.decorate.PrettyPrintingJsonGeneratorDecorator"/>

      <providers>

        <!-- 원하는 필드를 <pattern>으로 정의 -->
        <pattern>
          <pattern>
            {
              "@timestamp" : "%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z',UTC}",
              "level"      : "%level",
              "logger"     : "%logger{36}",
              "thread"     : "%thread",
              "service" : {
                "name"    : "${APP_NAME}",
                "version" : "${APP_VERSION}",
                "env"     : "${APP_ENV}"
              },
              "process" : {
                "pid" : "${PID:-0}"
              }
            }
          </pattern>
        </pattern>

        <!-- message, MDC, 예외는 별도 프로바이더 -->
        <message/>
        <mdc/>
        <stackTrace>
          <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
            <rootCauseFirst>true</rootCauseFirst>
            <maxDepthPerThrowable>20</maxDepthPerThrowable>
            <maxLength>4096</maxLength>
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
        String tId = http.getHeader("X-Transaction-Id");
        if (tId == null || tId.isBlank()) tId = UUID.randomUUID().toString();

        MDC.put("tId", tId);
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

@Slf4j
@Service
public class OrderService {

    public void placeOrder(String orderId, int amount) {
        log.info("주문 접수", keyValue("orderId", orderId), keyValue("amount", amount));

        try {
            validate(amount);
            log.info("주문 완료", keyValue("orderId", orderId));

        } catch (IllegalArgumentException e) {
            log.error("주문 유효성 오류 orderId={}", orderId, e);
            throw e;
        }
    }

    private void validate(int amount) {
        if (amount <= 0) throw new IllegalArgumentException("금액 오류: " + amount);
    }
}
```

---

## 7. 출력 예시

### 정상 요청 (INFO)

```json
{
  "@timestamp" : "2024-03-15T10:23:45.123Z",
  "level" : "INFO",
  "logger" : "c.e.service.OrderService",
  "thread" : "http-nio-8080-exec-3",
  "service" : {
    "name" : "order-service",
    "version" : "2.1.0",
    "env" : "local"
  },
  "process" : {
    "pid" : "12345"
  },
  "message" : "주문 접수",
  "tId" : "a1b2-c3d4-e5f6",
  "orderId" : "ORD-001",
  "amount" : 15000
}
```

### 예외 발생 (ERROR + Throwable)

```json
{
  "@timestamp" : "2024-03-15T10:23:45.456Z",
  "level" : "ERROR",
  "logger" : "c.e.service.OrderService",
  "thread" : "http-nio-8080-exec-3",
  "service" : {
    "name" : "order-service",
    "version" : "2.1.0",
    "env" : "local"
  },
  "process" : {
    "pid" : "12345"
  },
  "message" : "주문 유효성 오류 orderId=ORD-001",
  "tId" : "a1b2-c3d4-e5f6",
  "stack_trace" : "java.lang.IllegalArgumentException: 금액 오류: 0\n\tat com.example.service.OrderService.validate(OrderService.java:22)\n\t..."
}
```

---

## 8. `<pattern>` 에서 사용 가능한 주요 변수

| 표현식 | 설명 | 예시 출력 |
|--------|------|-----------|
| `%d{...}` | 날짜·시각 포맷 | `2024-03-15T10:23:45.123Z` |
| `%level` | 로그 레벨 | `INFO` |
| `%logger{N}` | Logger 이름 (N자리로 축약) | `c.e.service.OrderService` |
| `%thread` | 스레드 이름 | `http-nio-8080-exec-3` |
| `%message` | 로그 메시지 | `주문 접수` |
| `%X{key}` | MDC 특정 키 참조 | `a1b2-c3d4` |
| `${VAR:-default}` | 시스템/컨텍스트 프로퍼티 | `order-service` |
| `%replace(expr){'regex','replacement'}` | 값 치환 | 빈 값 → `""` |

> `<pattern>` 안에서는 시스템 프로퍼티(`${VAR}`)와 Logback 패턴(`%level` 등)만 사용 가능합니다.
> 스레드 내부 런타임 값(ThreadLocal 등)이 필요하면 MDC 브릿징 또는 Custom JsonProvider를 사용하세요.

---

## 9. 같이 보기

- [CompositeJsonEncoder ECS 설정 & 동적 키 생성](logback-ecs-composite-dynamic-keys.md)
- [logstash-logback-encoder Provider 필드 정리](../springboot/logback-providers.md)
- [Logback 코드 내부 값을 JSON으로 출력](../springboot/logback-internal-values.md)
