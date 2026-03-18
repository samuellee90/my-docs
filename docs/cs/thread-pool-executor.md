# ThreadPoolExecutor (스레드 풀 실행기)

## 개념

ThreadPoolExecutor는 **미리 생성된 스레드들의 풀을 관리하며 작업을 병렬로 처리하는 실행기(Executor)**다.

매번 스레드를 새로 생성/소멸하는 비용 없이, 스레드를 재사용함으로써 성능을 높인다.

### 왜 필요한가?

| 방식 | 문제점 |
|------|--------|
| `new Thread()` 직접 생성 | 요청마다 스레드 생성 → 생성 비용 큼, 무제한 생성 위험 |
| ThreadPoolExecutor | 스레드 재사용, 최대 스레드 수 제한, 큐잉 지원 |

---

## 핵심 파라미터

```
ThreadPoolExecutor(
    int corePoolSize,       // 기본으로 유지할 스레드 수
    int maximumPoolSize,    // 최대 스레드 수
    long keepAliveTime,     // 초과 스레드 유휴 시 유지 시간
    TimeUnit unit,          // keepAliveTime 단위
    BlockingQueue workQueue // 대기 작업 큐
)
```

### 작업 처리 흐름

```
작업 제출
    │
    ▼
corePoolSize 이하? ──YES──▶ 새 스레드 생성 후 처리
    │
   NO
    ▼
큐에 여유 있음? ──YES──▶ 큐에 삽입 (대기)
    │
   NO
    ▼
maximumPoolSize 이하? ──YES──▶ 새 스레드 생성 후 처리
    │
   NO
    ▼
RejectedExecutionHandler 실행 (기본: AbortPolicy → 예외 발생)
```

---

## Java 예제 코드

### 1. 기본 사용 (Executors 팩토리)

```java
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class BasicThreadPool {
    public static void main(String[] args) {
        // 고정 크기 스레드 풀 (core = max = 5)
        ExecutorService executor = Executors.newFixedThreadPool(5);

        for (int i = 1; i <= 10; i++) {
            final int taskId = i;
            executor.submit(() -> {
                System.out.println("작업 " + taskId + " - 스레드: " + Thread.currentThread().getName());
                Thread.sleep(500); // 작업 시뮬레이션
                return null;
            });
        }

        executor.shutdown(); // 새 작업 제출 중단, 기존 작업 완료 후 종료
    }
}
```

---

### 2. ThreadPoolExecutor 직접 생성

```java
import java.util.concurrent.*;

public class CustomThreadPool {
    public static void main(String[] args) throws InterruptedException {
        ThreadPoolExecutor executor = new ThreadPoolExecutor(
            2,                          // corePoolSize
            5,                          // maximumPoolSize
            60L,                        // keepAliveTime
            TimeUnit.SECONDS,           // 단위
            new ArrayBlockingQueue<>(10) // 큐 용량
        );

        for (int i = 1; i <= 7; i++) {
            final int taskId = i;
            executor.execute(() -> {
                System.out.printf("[%s] 작업 %d 시작%n",
                    Thread.currentThread().getName(), taskId);
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                System.out.printf("[%s] 작업 %d 완료%n",
                    Thread.currentThread().getName(), taskId);
            });

            // 스레드 풀 상태 출력
            System.out.printf("활성 스레드: %d, 큐 크기: %d%n",
                executor.getActiveCount(), executor.getQueue().size());
        }

        executor.shutdown();
        executor.awaitTermination(10, TimeUnit.SECONDS);
    }
}
```

---

### 3. Future로 결과 받기

```java
import java.util.concurrent.*;
import java.util.List;
import java.util.ArrayList;

public class FutureExample {
    public static void main(String[] args) throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(3);
        List<Future<Integer>> futures = new ArrayList<>();

        // 작업 제출 (Callable → 결과 반환)
        for (int i = 1; i <= 5; i++) {
            final int num = i;
            Future<Integer> future = executor.submit(() -> {
                Thread.sleep(300);
                return num * num; // 제곱 반환
            });
            futures.add(future);
        }

        // 결과 수집
        for (Future<Integer> future : futures) {
            System.out.println("결과: " + future.get()); // blocking
        }

        executor.shutdown();
    }
}
```

---

### 4. RejectedExecutionHandler (거절 정책)

```java
import java.util.concurrent.*;

public class RejectionPolicyExample {
    public static void main(String[] args) {
        ThreadPoolExecutor executor = new ThreadPoolExecutor(
            1, 2, 60L, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(2),
            new ThreadPoolExecutor.CallerRunsPolicy() // 거절 시 호출 스레드가 직접 실행
        );

        for (int i = 1; i <= 6; i++) {
            final int taskId = i;
            executor.execute(() -> {
                System.out.println("작업 " + taskId + " 실행: " + Thread.currentThread().getName());
                try { Thread.sleep(500); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            });
        }

        executor.shutdown();
    }
}
```

| 정책 | 동작 |
|------|------|
| `AbortPolicy` (기본) | `RejectedExecutionException` 예외 발생 |
| `CallerRunsPolicy` | 호출한 스레드가 직접 실행 |
| `DiscardPolicy` | 조용히 작업 버림 |
| `DiscardOldestPolicy` | 큐에서 가장 오래된 작업 제거 후 재시도 |

---

## Executors 팩토리 메서드 비교

| 메서드 | 설명 | 내부 구성 |
|--------|------|-----------|
| `newFixedThreadPool(n)` | 고정 크기 풀 | core = max = n, 무제한 큐 |
| `newCachedThreadPool()` | 가변 크기 풀 | core = 0, max = Integer.MAX_VALUE |
| `newSingleThreadExecutor()` | 단일 스레드 | core = max = 1, 순서 보장 |
| `newScheduledThreadPool(n)` | 예약 실행 풀 | 지연/반복 작업용 |

> **주의:** `newCachedThreadPool()`과 `newFixedThreadPool()`에 무제한 큐는 OOM 위험이 있으므로 운영 환경에서는 `ThreadPoolExecutor`를 직접 생성해 파라미터를 명시하는 것이 권장된다.

---

## 관련 개념

- [프로세스와 스레드](cs/process-thread.md)
