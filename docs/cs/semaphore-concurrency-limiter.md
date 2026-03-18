# SemaphoreConcurrencyLimiter

## 개념

### ConcurrencyLimiter란?

`ConcurrencyLimiter`는 **동시에 실행 가능한 작업 수를 제한하는 인터페이스**다. 외부 API 호출, DB 커넥션, 공유 자원 접근 등에서 과부하를 방지하기 위해 사용한다.

```java
public interface ConcurrencyLimiter {
    void acquire() throws InterruptedException;  // 실행 허가 획득 (대기)
    void release();                              // 실행 완료 후 반납
}
```

### SemaphoreConcurrencyLimiter란?

`SemaphoreConcurrencyLimiter`는 **Java의 `Semaphore`를 이용해 `ConcurrencyLimiter`를 구현한 클래스**다.

`Semaphore`는 내부에 **permit(허가권)** 을 정해진 수만큼 갖고 있으며, 작업이 시작될 때 permit을 하나 가져가고(acquire), 작업이 끝나면 반납(release)한다. permit이 0이 되면 이후 요청은 반납될 때까지 대기한다.

```
permit = 3 (최대 동시 실행 3개)

요청1 ──▶ acquire() → permit=2 → [실행 중]
요청2 ──▶ acquire() → permit=1 → [실행 중]
요청3 ──▶ acquire() → permit=0 → [실행 중]
요청4 ──▶ acquire() → permit=0 → [대기...] ← 블로킹
요청5 ──▶ acquire() → permit=0 → [대기...] ← 블로킹

요청1 완료 → release() → permit=1
요청4 ──────────────────────────▶ [실행 시작]
```

---

## 구조

```
«interface»
ConcurrencyLimiter
  + acquire(): void
  + release(): void
        ▲
        │ implements
        │
SemaphoreConcurrencyLimiter
  - semaphore: Semaphore
  + SemaphoreConcurrencyLimiter(int limit)
  + acquire(): void
  + release(): void
```

---

## Java 예제 코드

### 1. 인터페이스 & 구현체 정의

```java
// ConcurrencyLimiter.java
public interface ConcurrencyLimiter {
    void acquire() throws InterruptedException;
    void release();
}
```

```java
// SemaphoreConcurrencyLimiter.java
import java.util.concurrent.Semaphore;

public class SemaphoreConcurrencyLimiter implements ConcurrencyLimiter {

    private final Semaphore semaphore;

    public SemaphoreConcurrencyLimiter(int limit) {
        this.semaphore = new Semaphore(limit);
    }

    @Override
    public void acquire() throws InterruptedException {
        semaphore.acquire(); // permit 획득 (없으면 대기)
    }

    @Override
    public void release() {
        semaphore.release(); // permit 반납
    }

    public int availablePermits() {
        return semaphore.availablePermits();
    }
}
```

---

### 2. 기본 동작 확인

```java
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class BasicExample {
    public static void main(String[] args) throws InterruptedException {
        ConcurrencyLimiter limiter = new SemaphoreConcurrencyLimiter(3); // 최대 동시 3개
        ExecutorService executor = Executors.newFixedThreadPool(10);

        for (int i = 1; i <= 8; i++) {
            final int taskId = i;
            executor.submit(() -> {
                try {
                    limiter.acquire();
                    System.out.printf("[%s] 작업 %d 시작 (남은 permit: %d)%n",
                        Thread.currentThread().getName(), taskId,
                        ((SemaphoreConcurrencyLimiter) limiter).availablePermits());

                    Thread.sleep(1000); // 작업 시뮬레이션

                    System.out.printf("[%s] 작업 %d 완료%n",
                        Thread.currentThread().getName(), taskId);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    limiter.release(); // 반드시 finally에서 반납
                }
            });
        }

        executor.shutdown();
    }
}
```

**출력 예시:**
```
[pool-1-thread-1] 작업 1 시작 (남은 permit: 2)
[pool-1-thread-2] 작업 2 시작 (남은 permit: 1)
[pool-1-thread-3] 작업 3 시작 (남은 permit: 0)
// 1~3 완료 후 4~6 시작
[pool-1-thread-4] 작업 4 시작 (남은 permit: 2)
...
```

---

### 3. 외부 API 호출 제한 (실전 패턴)

```java
import java.util.concurrent.*;
import java.util.List;
import java.util.ArrayList;

public class ApiCallLimitExample {

    private final ConcurrencyLimiter limiter;

    public ApiCallLimitExample(int maxConcurrent) {
        this.limiter = new SemaphoreConcurrencyLimiter(maxConcurrent);
    }

    public String callExternalApi(int requestId) throws InterruptedException {
        limiter.acquire();
        try {
            System.out.printf("API 호출 %d 시작%n", requestId);
            Thread.sleep(500); // 외부 API 응답 대기 시뮬레이션
            return "응답 " + requestId;
        } finally {
            limiter.release();
        }
    }

    public static void main(String[] args) throws Exception {
        ApiCallLimitExample service = new ApiCallLimitExample(2); // 동시 최대 2개
        ExecutorService executor = Executors.newFixedThreadPool(6);
        List<Future<String>> futures = new ArrayList<>();

        for (int i = 1; i <= 6; i++) {
            final int id = i;
            futures.add(executor.submit(() -> service.callExternalApi(id)));
        }

        for (Future<String> f : futures) {
            System.out.println("결과: " + f.get());
        }

        executor.shutdown();
    }
}
```

---

### 4. tryAcquire로 타임아웃 처리

```java
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

public class TryAcquireExample {

    private final Semaphore semaphore;

    public TryAcquireExample(int limit) {
        this.semaphore = new Semaphore(limit);
    }

    public void execute(int taskId) {
        try {
            // 500ms 안에 permit 획득 실패 시 포기
            boolean acquired = semaphore.tryAcquire(500, TimeUnit.MILLISECONDS);
            if (!acquired) {
                System.out.printf("작업 %d: 대기 시간 초과, 요청 거절%n", taskId);
                return;
            }
            try {
                System.out.printf("작업 %d 실행 중%n", taskId);
                Thread.sleep(1000);
            } finally {
                semaphore.release();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public static void main(String[] args) {
        TryAcquireExample limiter = new TryAcquireExample(2);
        ExecutorService executor = Executors.newFixedThreadPool(5);

        for (int i = 1; i <= 5; i++) {
            final int id = i;
            executor.submit(() -> limiter.execute(id));
        }

        executor.shutdown();
    }
}
```

---

### 5. Spring 서비스에서 활용 패턴

```java
import org.springframework.stereotype.Service;
import java.util.concurrent.Semaphore;

@Service
public class ExternalApiService {

    // 외부 API 동시 호출 최대 5개로 제한
    private final ConcurrencyLimiter limiter = new SemaphoreConcurrencyLimiter(5);

    public String fetchData(String endpoint) throws InterruptedException {
        limiter.acquire();
        try {
            // 실제 HTTP 호출 (예: RestTemplate, WebClient 등)
            return callApi(endpoint);
        } finally {
            limiter.release();
        }
    }

    private String callApi(String endpoint) {
        // HTTP 호출 로직
        return "data from " + endpoint;
    }
}
```

---

## Semaphore vs synchronized vs ReentrantLock

| 항목 | `synchronized` | `ReentrantLock` | `Semaphore` |
|------|---------------|-----------------|-------------|
| 동시 접근 허용 수 | 1개 | 1개 | N개 (지정 가능) |
| 타임아웃 지원 | 불가 | 가능 | 가능 |
| 공정성(fairness) | 불가 | 가능 | 가능 |
| 주요 용도 | 단순 mutual exclusion | 유연한 lock | 동시 실행 수 제한 |

---

## 주의사항

- `release()`는 반드시 `finally` 블록에서 호출해야 한다. 예외 발생 시 permit이 반납되지 않으면 **데드락**이 발생한다.
- `acquire()`를 호출한 스레드와 `release()`를 호출하는 스레드가 달라도 된다 (`ReentrantLock`과의 차이).
- 공정한 순서가 필요하면 `new Semaphore(limit, true)` 로 fair 모드를 활성화한다.

---

## 관련 개념

- [ThreadPoolExecutor](cs/thread-pool-executor.md)
- [Future & CompletableFuture](cs/future.md)
- [프로세스와 스레드](cs/process-thread.md)
