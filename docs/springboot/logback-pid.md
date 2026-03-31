# logback.xml — JSON 로그에 PID 주입

Java 21 + Spring Boot 환경에서 `LoggingEventCompositeJsonEncoder`를 사용할 때
프로세스 PID를 JSON 로그 필드에 주입하는 방법을 정리합니다.

---

## 방법 1. `<springProperty>` 활용 (권장)

Spring Boot는 시작 시 `spring.application.pid`를 시스템 프로퍼티로 자동 등록합니다.
파일명이 **`logback-spring.xml`** 이면 `<springProperty>`로 바로 받을 수 있습니다.

```xml
<springProperty name="PID" source="spring.application.pid"/>

<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <pattern>
      <pattern>
        {
          "pid": "${PID}",
          "timestamp": "%d{yyyy-MM-dd'T'HH:mm:ss.SSSZ}",
          "level": "%level",
          "logger": "%logger",
          "message": "%message"
        }
      </pattern>
    </pattern>
  </providers>
</encoder>
```

> `logback.xml`이 아닌 **`logback-spring.xml`** 이어야 `<springProperty>`가 동작합니다.

---

## 방법 2. `%pid` 내장 패턴 (Spring Boot 3.x / Logback 1.3+)

Spring Boot 3.x (Logback 1.3+) 환경에서는 `%pid` 컨버터가 내장 지원됩니다.
별도 설정 없이 바로 패턴에 사용할 수 있습니다.

```xml
<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <pattern>
      <pattern>
        {
          "pid": "%pid",
          "level": "%level",
          "logger": "%logger",
          "message": "%message"
        }
      </pattern>
    </pattern>
  </providers>
</encoder>
```

---

## 방법 3. `System.setProperty`로 수동 등록

`logback.xml`을 유지해야 하거나, 코드에서 직접 제어하고 싶을 때 사용합니다.

```java
// main() 또는 ApplicationRunner에서 Spring 초기화 전에 호출
long pid = ProcessHandle.current().pid(); // Java 9+
System.setProperty("APP_PID", String.valueOf(pid));
```

> 기존 코드의 `ManagementFactory.getRuntimeMXBean().getName()`은
> `"12345@hostname"` 형태이므로 파싱 필요:
> ```java
> String name = ManagementFactory.getRuntimeMXBean().getName();
> String pid = name.split("@")[0];
> System.setProperty("APP_PID", pid);
> ```

```xml
<!-- logback.xml -->
<property name="PID" value="${APP_PID:-unknown}"/>

<encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
  <providers>
    <pattern>
      <pattern>{"pid": "${PID}", "level": "%level", "message": "%message"}</pattern>
    </pattern>
  </providers>
</encoder>
```

---

## 방법 비교

| 방법 | 파일 | Spring Boot 버전 | 비고 |
|------|------|-----------------|------|
| `<springProperty>` | `logback-spring.xml` | 2.x / 3.x | 가장 간단, Spring 의존 |
| `%pid` 내장 패턴 | `logback.xml` / `logback-spring.xml` | 3.x (Logback 1.3+) | 설정 불필요 |
| `System.setProperty` | `logback.xml` | 2.x / 3.x | 코드 제어 필요, Spring 무관 |

> Java 21 + Spring Boot 3.x 기준 **방법 2 (`%pid`)** 가 가장 간결합니다.
> `logback-spring.xml`로 전환 가능하다면 **방법 1**도 좋습니다.
