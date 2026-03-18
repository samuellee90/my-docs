# Future & CompletableFuture

## Future란?

`Future<V>`는 **비동기 작업의 결과를 나타내는 인터페이스**다. 작업을 스레드 풀에 제출하면 즉시 `Future` 객체가 반환되고, 실제 결과는 나중에 `.get()`으로 가져온다.

```
메인 스레드         스레드 풀
    │                   │
    │── submit(task) ──▶│ 작업 시작
    │◀── Future ────────│ (즉시 반환)
    │                   │ (작업 진행 중...)
    │── future.get() ──▶│ (블로킹 대기)
    │◀── 결과 ──────────│ 작업 완료
```

---

## Future 주요 메서드

| 메서드 | 설명 |
|--------|------|
| `get()` | 결과 반환 (완료까지 블로킹) |
| `get(timeout, unit)` | 타임아웃 지정 블로킹 |
| `isDone()` | 완료 여부 확인 |
| `isCancelled()` | 취소 여부 확인 |
| `cancel(true)` | 작업 취소 시도 |

---

## Java 예제 코드

### 1. 기본 Future 사용

```java
import java.util.concurrent.*;

public class FutureBasic {
    public static void main(String[] args) throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(2);

        // Callable 제출 → Future 즉시 반환
        Future<String> future = executor.submit(() -> {
            Thread.sleep(1000); // 시간이 걸리는 작업
            return "작업 완료!";
        });

        System.out.println("작업 제출 후 다른 일 처리 중...");

        // 결과 필요 시점에 get() 호출 (완료될 때까지 블로킹)
        String result = future.get();
        System.out.println("결과: " + result);

        executor.shutdown();
    }
}
```

---

### 2. 타임아웃 & 취소

```java
import java.util.concurrent.*;

public class FutureTimeout {
    public static void main(String[] args) {
        ExecutorService executor = Executors.newSingleThreadExecutor();

        Future<String> future = executor.submit(() -> {
            Thread.sleep(5000); // 5초 작업
            return "완료";
        });

        try {
            // 2초 내에 완료되지 않으면 TimeoutException
            String result = future.get(2, TimeUnit.SECONDS);
            System.out.println(result);
        } catch (TimeoutException e) {
            System.out.println("타임아웃 → 작업 취소");
            future.cancel(true); // 인터럽트로 취소 시도
        } catch (InterruptedException | ExecutionException e) {
            e.printStackTrace();
        } finally {
            executor.shutdown();
        }
    }
}
```

---

### 3. 여러 Future 병렬 처리

```java
import java.util.concurrent.*;
import java.util.*;

public class MultipleFutures {
    public static void main(String[] args) throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(4);
        List<Future<Integer>> futures = new ArrayList<>();

        // 4개의 작업을 동시에 제출
        for (int i = 1; i <= 4; i++) {
            final int num = i;
            futures.add(executor.submit(() -> {
                Thread.sleep(500);
                return num * num;
            }));
        }

        // 결과 순서대로 수집 (각각 블로킹)
        int total = 0;
        for (Future<Integer> f : futures) {
            total += f.get();
        }
        System.out.println("합계: " + total); // 1+4+9+16 = 30

        executor.shutdown();
    }
}
```

---

## Future의 한계

```java
// 1. 체이닝 불가 — 결과를 받아 다음 작업으로 넘기려면 직접 코딩해야 함
String result = future.get();         // 블로킹
String upper = result.toUpperCase();  // 그 다음에야 가능

// 2. 예외 처리 불편 — get()에서 checked 예외 두 개 처리 필수
try {
    future.get();
} catch (InterruptedException | ExecutionException e) { ... }

// 3. 콜백 없음 — 완료 시점을 능동적으로 알 수 없고 계속 get()으로 기다려야 함
```

---

## CompletableFuture (Java 8+)

`Future`의 한계를 해결한 **비동기 파이프라인 API**. 콜백, 체이닝, 예외 처리를 선언형으로 표현할 수 있다.

### 주요 메서드

| 메서드 | 설명 |
|--------|------|
| `supplyAsync(supplier)` | 값을 반환하는 비동기 작업 시작 |
| `runAsync(runnable)` | 반환값 없는 비동기 작업 시작 |
| `thenApply(fn)` | 결과 변환 (map과 유사) |
| `thenAccept(consumer)` | 결과 소비 (반환 없음) |
| `thenCompose(fn)` | 다른 CompletableFuture와 체이닝 (flatMap과 유사) |
| `thenCombine(other, fn)` | 두 결과 합치기 |
| `exceptionally(fn)` | 예외 처리 |
| `join()` | get()과 유사, unchecked 예외 발생 |

---

### 4. CompletableFuture 체이닝

```java
import java.util.concurrent.CompletableFuture;

public class CompletableFutureChain {
    public static void main(String[] args) throws Exception {
        CompletableFuture<String> cf = CompletableFuture
            .supplyAsync(() -> {
                System.out.println("1단계: 데이터 조회");
                return 42;
            })
            .thenApply(data -> {
                System.out.println("2단계: 가공 → " + data);
                return "결과: " + (data * 2);
            })
            .thenApply(String::toUpperCase);

        System.out.println(cf.get()); // 결과: 84 → 대문자 변환
    }
}
```

---

### 5. CompletableFuture 예외 처리

```java
import java.util.concurrent.CompletableFuture;

public class CompletableFutureException {
    public static void main(String[] args) throws Exception {
        CompletableFuture<String> cf = CompletableFuture
            .supplyAsync(() -> {
                if (true) throw new RuntimeException("API 호출 실패");
                return "성공";
            })
            .exceptionally(ex -> {
                System.out.println("예외 처리: " + ex.getMessage());
                return "기본값";
            })
            .thenApply(result -> "[" + result + "]");

        System.out.println(cf.get()); // [기본값]
    }
}
```

---

### 6. 두 작업 병렬 실행 후 합치기

```java
import java.util.concurrent.CompletableFuture;

public class CompletableFutureCombine {
    public static void main(String[] args) throws Exception {
        CompletableFuture<String> userFuture = CompletableFuture
            .supplyAsync(() -> {
                // DB에서 사용자 조회 (시뮬레이션)
                return "Alice";
            });

        CompletableFuture<Integer> scoreFuture = CompletableFuture
            .supplyAsync(() -> {
                // 점수 계산 (시뮬레이션)
                return 95;
            });

        // 두 작업이 모두 완료되면 결과 합치기
        String combined = userFuture
            .thenCombine(scoreFuture, (user, score) -> user + "의 점수: " + score)
            .get();

        System.out.println(combined); // Alice의 점수: 95
    }
}
```

---

### 7. 여러 작업 중 가장 빠른 결과만 사용

```java
import java.util.concurrent.CompletableFuture;

public class CompletableFutureAnyOf {
    public static void main(String[] args) throws Exception {
        CompletableFuture<String> server1 = CompletableFuture.supplyAsync(() -> {
            try { Thread.sleep(300); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return "서버1 응답";
        });

        CompletableFuture<String> server2 = CompletableFuture.supplyAsync(() -> {
            try { Thread.sleep(100); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return "서버2 응답";
        });

        // 가장 먼저 완료된 결과 사용
        Object fastest = CompletableFuture.anyOf(server1, server2).get();
        System.out.println(fastest); // 서버2 응답
    }
}
```

---

## Future vs CompletableFuture 비교

| 항목 | Future | CompletableFuture |
|------|--------|-------------------|
| 결과 조회 | `get()` 블로킹만 가능 | `get()` / `join()` / 콜백 모두 가능 |
| 체이닝 | 불가 | `thenApply`, `thenCompose` 등 |
| 예외 처리 | try-catch 필수 | `exceptionally`, `handle` |
| 병렬 조합 | 수동 구현 | `thenCombine`, `allOf`, `anyOf` |
| 외부에서 완료 | 불가 | `complete(value)` 직접 완료 가능 |

---

## 관련 개념

- [ThreadPoolExecutor](cs/thread-pool-executor.md)
- [프로세스와 스레드](cs/process-thread.md)
