# EcsEncoder — co.elastic.logging.logback.EcsEncoder 완전 가이드

Elastic이 공식 제공하는 ECS(Elastic Common Schema) 전용 Logback 인코더 사용법을 정리합니다.
`LoggingEventCompositeJsonEncoder`와 달리 ECS 필드 구조를 라이브러리 수준에서 보장하므로
Elasticsearch · OpenSearch 수집 파이프라인에 바로 연결할 수 있습니다.

---

## 1. 의존성 추가

### 필수 — ECS Logback 인코더

```xml
<!-- pom.xml -->
<dependency>
  <groupId>co.elastic.logging</groupId>
  <artifactId>logback-ecs-encoder</artifactId>
  <version>1.6.0</version>
</dependency>
```

```groovy
// build.gradle
implementation 'co.elastic.logging:logback-ecs-encoder:1.6.0'
```

### 선택 — StructuredArguments 동적 키 지원

`EcsEncoder`는 classpath에 `logstash-logback-encoder`가 있으면 `StructuredArguments`를 자동 감지해 JSON 필드로 출력합니다.
MDC 없이 호출 시점에 동적 키를 추가하려면 아래 의존성을 함께 추가하세요.

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

## 2. 예약 필드 (Reserved ECS Fields) 전체 정리

`EcsEncoder`가 자동으로 출력하는 필드입니다. 이 키 이름은 ECS 스펙에 예약되어 있으므로
`additionalField`나 MDC에 같은 이름을 사용하면 충돌이 발생합니다.

| ECS 필드 | 설명 | 출력 조건 |
|----------|------|-----------|
| `@timestamp` | ISO8601 UTC 타임스탬프 (`yyyy-MM-dd'T'HH:mm:ss.SSSZ`) | 항상 |
| `log.level` | 로그 레벨 (`INFO`, `ERROR`, `WARN`, `DEBUG`, `TRACE`) | 항상 |
| `log.logger` | Logger 전체 클래스명 | 항상 |
| `log.origin.file.name` | 소스 파일명 (`OrderService.java`) | `includeOrigin=true` |
| `log.origin.file.line` | 소스 라인 번호 | `includeOrigin=true` |
| `log.origin.function` | 메서드명 | `includeOrigin=true` |
| `message` | 로그 메시지 본문 | 항상 |
| `error.type` | 예외 클래스 FQCN | Throwable 전달 시 |
| `error.message` | 예외 메시지 | Throwable 전달 시 |
| `error.stack_trace` | 스택 트레이스 (문자열 또는 배열) | Throwable 전달 시 |
| `service.name` | 서비스 이름 | `serviceName` 설정 시 |
| `service.version` | 서비스 버전 | `serviceVersion` 설정 시 |
| `service.environment` | 배포 환경 (`production`, `staging` 등) | `serviceEnvironment` 설정 시 |
| `service.node.name` | 서비스 노드(인스턴스) 이름 | `serviceNodeName` 설정 시 |
| `event.dataset` | 데이터셋 이름 (기본값: `serviceName.log`) | 항상 (serviceName 설정 시) |
| `process.thread.name` | 현재 스레드 이름 | 항상 |
| `process.pid` | 프로세스 ID | JVM이 PID를 노출하는 경우 |
| `host.hostname` | 호스트명 | `hostName` 설정 또는 자동 감지 |
| `transaction.id` | Elastic APM 트랜잭션 ID | Elastic APM 에이전트 + MDC 연동 시 |
| `trace.id` | Elastic APM 분산 추적 ID | Elastic APM 에이전트 + MDC 연동 시 |
| `span.id` | Elastic APM 스팬 ID | Elastic APM 에이전트 + MDC 연동 시 |

> `log.origin.*` 필드는 Logback의 caller data 추출(`includeCallerData`)이 필요하므로
> **성능 비용**이 있습니다. 운영 환경에서는 기본값(`false`) 유지를 권장합니다.

---

## 3. logback.xml 기본 설정

`EcsEncoder`에서 설정 가능한 모든 옵션을 포함한 예시입니다.

```xml
<!-- src/main/resources/logback-spring.xml -->
<configuration>

  <!-- Spring 프로퍼티를 Logback context 변수로 바인딩 -->
  <springProperty scope="context" name="APP_NAME"    source="spring.application.name"  defaultValue="unknown"/>
  <springProperty scope="context" name="APP_VERSION" source="spring.application.version" defaultValue=""/>
  <springProperty scope="context" name="APP_ENV"     source="spring.profiles.active"    defaultValue="local"/>
  <springProperty scope="context" name="APP_NODE"    source="spring.cloud.client.hostname" defaultValue=""/>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="co.elastic.logging.logback.EcsEncoder">

      <!-- ── service.* 필드 ───────────────────────────────── -->
      <serviceName>${APP_NAME}</serviceName>
      <serviceVersion>${APP_VERSION}</serviceVersion>
      <serviceEnvironment>${APP_ENV}</serviceEnvironment>
      <serviceNodeName>${APP_NODE}</serviceNodeName>

      <!-- event.dataset (기본값: serviceName.log) -->
      <!-- <eventDataset>${APP_NAME}.application</eventDataset> -->

      <!-- ── log.origin.* 필드 (성능 비용 있음, 기본 false) ── -->
      <includeOrigin>false</includeOrigin>

      <!-- ── error.stack_trace 형식 ────────────────────────── -->
      <!-- true: 배열로 출력 (한 줄 = 한 요소), false: 문자열 한 덩어리 -->
      <stackTraceAsArray>false</stackTraceAsArray>

      <!-- ── 정적 사용자 정의 필드 (아래 섹션에서 자세히 설명) ── -->
      <additionalField>
        <key>team</key>
        <value>platform</value>
      </additionalField>

    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>

</configuration>
```

### 출력 예시 (기본)

```json
{
  "@timestamp": "2024-03-15T10:23:45.123Z",
  "log.level": "INFO",
  "log.logger": "com.example.service.OrderService",
  "message": "주문 접수",
  "service.name": "order-service",
  "service.version": "2.1.0",
  "service.environment": "production",
  "event.dataset": "order-service.log",
  "process.thread.name": "http-nio-8080-exec-3",
  "process.pid": 12345,
  "team": "platform"
}
```

---

## 4. 사용자 정의 키 — additionalField

`<additionalField>`는 logback.xml에 선언한 **정적** 키-값을 모든 로그에 포함합니다.
`<springProperty>`로 바인딩한 변수를 `${VAR}` 형태로 참조할 수 있습니다.

```xml
<springProperty scope="context" name="APP_NAME"    source="spring.application.name" defaultValue="app"/>
<springProperty scope="context" name="APP_VERSION" source="spring.application.version" defaultValue=""/>
<springProperty scope="context" name="DEPLOY_REGION" source="cloud.region" defaultValue="ap-northeast-2"/>

<appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
  <encoder class="co.elastic.logging.logback.EcsEncoder">
    <serviceName>${APP_NAME}</serviceName>
    <serviceVersion>${APP_VERSION}</serviceVersion>

    <!-- 애플리케이션 고유 정적 메타데이터 -->
    <additionalField>
      <key>team</key>
      <value>platform</value>
    </additionalField>

    <!-- Spring property 값 참조 -->
    <additionalField>
      <key>cloud.region</key>
      <value>${DEPLOY_REGION}</value>
    </additionalField>

    <!-- 시스템 환경 변수 참조 -->
    <additionalField>
      <key>host.pod_name</key>
      <value>${POD_NAME:-unknown}</value>
    </additionalField>
    <additionalField>
      <key>host.pod_ip</key>
      <value>${POD_IP:-}</value>
    </additionalField>

  </encoder>
</appender>
```

> `additionalField` 값은 **기동 시점에 고정**됩니다.
> 요청마다 달라지는 값(주문 ID, 사용자 ID 등)은 아래 5절의 동적 키 방법을 사용하세요.

---

## 5. 동적 키 표시 — logback.xml 설정 없이

`EcsEncoder`는 classpath에 `logstash-logback-encoder`가 있으면
`StructuredArguments`와 `LogstashMarkers`를 자동 지원합니다.
**logback.xml을 수정하지 않아도** 로그 호출 시점에 임의의 키를 JSON 필드로 출력할 수 있습니다.

### 방법 A — StructuredArguments

```java
import static net.logstash.logback.argument.StructuredArguments.*;

// 단일 키-값 (JSON: "orderId": "ORD-001")
log.info("주문 접수", keyValue("orderId", "ORD-001"));

// 축약형 kv (keyValue와 동일)
log.info("주문 접수", kv("orderId", "ORD-001"));

// 메시지 치환 + JSON 필드 동시 출력
// message: "주문 접수 [orderId=ORD-001]", JSON: "orderId": "ORD-001"
log.info("주문 접수 {}", value("orderId", "ORD-001"));

// 여러 키-값
log.info("결제 완료",
    kv("orderId", orderId),
    kv("amount", amount),           // 숫자 타입 그대로 출력
    kv("currency", "KRW")
);

// Map 전체를 최상위 필드로 펼치기
Map<String, Object> result = Map.of(
    "orderId",  orderId,
    "itemCode", itemCode,
    "status",   "COMPLETED"
);
log.info("주문 완료", entries(result));
// → "orderId": "...", "itemCode": "...", "status": "COMPLETED"

// 배열 필드
log.info("태그 목록", array("tags", "vip", "fast-delivery", "gift"));
// → "tags": ["vip", "fast-delivery", "gift"]

// 이미 직렬화된 JSON 문자열을 오브젝트로 삽입
log.info("페이로드", raw("payload", "{\"key\":\"value\"}"));
// → "payload": {"key": "value"}
```

### 방법 B — LogstashMarkers

`Marker`를 첫 번째 인자로 전달하는 방식입니다. `.and()`로 체이닝할 수 있습니다.

```java
import static net.logstash.logback.marker.Markers.*;

// 단일 키-값
log.info(append("orderId", "ORD-001"), "주문 접수");

// Map 전체 펼치기
Map<String, Object> ctx = Map.of("orderId", "ORD-001", "amount", 15000);
log.info(appendEntries(ctx), "주문 완료");

// 체이닝 — 여러 필드
log.info(
    append("orderId", orderId)
        .and(append("step", "payment"))
        .and(appendArray("items", "ITEM-A", "ITEM-B")),
    "결제 처리"
);
// → "orderId": "...", "step": "payment", "items": ["ITEM-A", "ITEM-B"]
```

> Marker가 **반드시 첫 번째 인자**여야 합니다. `log.info("msg", marker)` 순서는 동작하지 않습니다.

---

## 6. 전체 예제

### 프로젝트 구조

```
src/main/
├─ java/com/example/
│   ├─ service/
│   │   └─ OrderService.java
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

spring.application.version: "2.1.0"
spring.profiles.active: production
```

### logback-spring.xml

```xml
<configuration>

  <springProperty scope="context" name="APP_NAME"    source="spring.application.name"    defaultValue="app"/>
  <springProperty scope="context" name="APP_VERSION" source="spring.application.version"  defaultValue=""/>
  <springProperty scope="context" name="APP_ENV"     source="spring.profiles.active"      defaultValue="local"/>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="co.elastic.logging.logback.EcsEncoder">
      <serviceName>${APP_NAME}</serviceName>
      <serviceVersion>${APP_VERSION}</serviceVersion>
      <serviceEnvironment>${APP_ENV}</serviceEnvironment>
      <stackTraceAsArray>false</stackTraceAsArray>
      <includeOrigin>false</includeOrigin>

      <!-- 정적 추가 필드 -->
      <additionalField>
        <key>host.pod_name</key>
        <value>${POD_NAME:-local}</value>
      </additionalField>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>

</configuration>
```

### OrderService.java

```java
package com.example.service;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.Map;

import static net.logstash.logback.argument.StructuredArguments.*;
import static net.logstash.logback.marker.Markers.*;

@Slf4j
@Service
public class OrderService {

    public void placeOrder(String orderId, int amount, String itemCode) {

        // 단일 키-값 (logback.xml 수정 없이 동적 출력)
        log.info("주문 접수", kv("orderId", orderId), kv("amount", amount));

        try {
            validate(amount);
            process(orderId, itemCode);

            // Map 전체를 동적 필드로 펼치기
            Map<String, Object> result = Map.of(
                "orderId",  orderId,
                "itemCode", itemCode,
                "status",   "COMPLETED"
            );
            log.info("주문 완료", entries(result));

        } catch (IllegalArgumentException e) {
            // Throwable → error.type / error.message / error.stack_trace 자동 생성
            log.error("주문 유효성 오류", kv("orderId", orderId), e);
            throw e;
        } catch (Exception e) {
            log.error("주문 처리 실패", kv("orderId", orderId), e);
            throw new RuntimeException("주문 오류", e);
        }
    }

    public void processPayment(String paymentId, String orderId) {
        // LogstashMarkers 체이닝 예시
        log.info(
            append("paymentId", paymentId).and(append("orderId", orderId)),
            "결제 처리 시작"
        );
    }

    private void validate(int amount) {
        if (amount <= 0) throw new IllegalArgumentException("금액 오류: " + amount);
    }

    private void process(String orderId, String itemCode) {
        // 처리 로직
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

import static net.logstash.logback.argument.StructuredArguments.kv;

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

        log.info("주문 API 진입", kv("orderId", orderId));
        orderService.placeOrder(orderId, amount, itemCode);
        return "OK";
    }
}
```

---

## 7. 출력 예시

### 정상 주문 (INFO)

```json
{
  "@timestamp": "2024-03-15T10:23:45.123Z",
  "log.level": "INFO",
  "log.logger": "com.example.service.OrderService",
  "message": "주문 완료",
  "service.name": "order-service",
  "service.version": "2.1.0",
  "service.environment": "production",
  "event.dataset": "order-service.log",
  "process.thread.name": "http-nio-8080-exec-3",
  "process.pid": 12345,
  "host.pod_name": "order-pod-abc123",
  "orderId": "ORD-001",
  "itemCode": "ITEM-42",
  "status": "COMPLETED"
}
```

### 예외 발생 (ERROR + Throwable)

```json
{
  "@timestamp": "2024-03-15T10:23:45.456Z",
  "log.level": "ERROR",
  "log.logger": "com.example.service.OrderService",
  "message": "주문 유효성 오류",
  "service.name": "order-service",
  "service.version": "2.1.0",
  "service.environment": "production",
  "event.dataset": "order-service.log",
  "process.thread.name": "http-nio-8080-exec-3",
  "process.pid": 12345,
  "host.pod_name": "order-pod-abc123",
  "orderId": "ORD-001",
  "error.type": "java.lang.IllegalArgumentException",
  "error.message": "금액 오류: 0",
  "error.stack_trace": "java.lang.IllegalArgumentException: 금액 오류: 0\n\tat com.example.service.OrderService.validate(OrderService.java:38)\n\t..."
}
```

---

## 8. 동적 키 방법 비교

| 방법 | 키 결정 시점 | 적용 범위 | 비고 |
|------|------------|-----------|------|
| `additionalField` | 기동 시 고정 | 모든 로그 | Spring property 참조 가능 |
| `StructuredArguments.kv()` | 로그 호출 시점 | 해당 로그 라인 | `logstash-logback-encoder` 필요 |
| `StructuredArguments.entries()` | 로그 호출 시점 | 해당 로그 라인 | Map 전체를 필드로 펼칠 때 |
| `LogstashMarkers.append()` | 로그 호출 시점 | 해당 로그 라인 | `.and()` 체이닝, Marker 재사용 가능 |

---

## 9. EcsEncoder vs LoggingEventCompositeJsonEncoder

| 항목 | EcsEncoder | CompositeJsonEncoder |
|------|-----------|----------------------|
| ECS 필드 보장 | ✅ 라이브러리 수준 | 수동 설정 필요 |
| 설정 복잡도 | 낮음 | 높음 (Provider 조합) |
| 필드 구조 커스터마이징 | 제한적 | 자유롭게 가능 |
| StructuredArguments 지원 | ✅ (classpath 감지) | ✅ (`<arguments/>` 프로바이더) |
| Elastic 공식 지원 | ✅ | ❌ |

---

## 10. 같이 보기

- [ECS vs LoggingEventCompositeJsonEncoder 비교](../springboot/ecs-vs-logback-json.md)
- [CompositeJsonEncoder ECS 설정 & 동적 키 생성](logback-ecs-composite-dynamic-keys.md)
- [동적 필드 주입 — MDC · Arguments · Markers · Provider](logback-dynamic-fields.md)
