# Java 예외 처리 (Exception Handling)

Java의 예외 계층 구조와 처리 방법을 예제 중심으로 정리합니다.

---

## 1. 예외 계층 구조

```
Throwable
├── Error                        (복구 불가능한 시스템 오류)
│   ├── OutOfMemoryError
│   ├── StackOverflowError
│   └── ...
└── Exception
    ├── RuntimeException         (Unchecked Exception)
    │   ├── NullPointerException
    │   ├── ArrayIndexOutOfBoundsException
    │   ├── ClassCastException
    │   ├── IllegalArgumentException
    │   ├── IllegalStateException
    │   └── ...
    └── IOException              (Checked Exception)
        ├── FileNotFoundException
        └── ...
```

---

## 2. Checked vs Unchecked

| 구분 | Checked Exception | Unchecked Exception |
|------|------------------|---------------------|
| 상속 | `Exception` | `RuntimeException` |
| 컴파일 강제 | O (반드시 처리) | X (선택) |
| 예시 | `IOException`, `SQLException` | `NullPointerException`, `IllegalArgumentException` |

---

## 3. 기본 try-catch-finally

```java
try {
    String s = null;
    s.length(); // NullPointerException 발생
} catch (NullPointerException e) {
    System.out.println("null 참조: " + e.getMessage());
} catch (Exception e) {
    System.out.println("알 수 없는 오류: " + e.getMessage());
} finally {
    System.out.println("항상 실행됨 (자원 해제 등)");
}
```

> `finally` 블록은 예외 발생 여부와 관계없이 항상 실행됩니다.

---

## 4. Multi-catch (Java 7+)

```java
try {
    // ...
} catch (IOException | SQLException e) {
    System.out.println("IO 또는 SQL 오류: " + e.getMessage());
}
```

---

## 5. try-with-resources (Java 7+)

`AutoCloseable`을 구현한 자원을 자동으로 닫아줍니다.

```java
// 기존 방식
BufferedReader br = null;
try {
    br = new BufferedReader(new FileReader("file.txt"));
    String line = br.readLine();
} catch (IOException e) {
    e.printStackTrace();
} finally {
    if (br != null) br.close();
}

// try-with-resources
try (BufferedReader br = new BufferedReader(new FileReader("file.txt"))) {
    String line = br.readLine();
} catch (IOException e) {
    e.printStackTrace();
}
```

---

## 6. 커스텀 예외 만들기

```java
// Checked Exception
public class InsufficientBalanceException extends Exception {
    private final double amount;

    public InsufficientBalanceException(double amount) {
        super("잔액 부족: " + amount + "원 필요");
        this.amount = amount;
    }

    public double getAmount() {
        return amount;
    }
}

// Unchecked Exception
public class InvalidUserException extends RuntimeException {
    public InvalidUserException(String userId) {
        super("유효하지 않은 사용자: " + userId);
    }
}
```

```java
// 사용 예시
public void withdraw(double amount) throws InsufficientBalanceException {
    if (balance < amount) {
        throw new InsufficientBalanceException(amount);
    }
    balance -= amount;
}
```

---

## 7. 예외 전파 (re-throw)

```java
public void process() throws IOException {
    try {
        readFile();
    } catch (IOException e) {
        System.err.println("파일 처리 실패: " + e.getMessage());
        throw e; // 다시 던지기
    }
}
```

```java
// 예외 감싸서 던지기 (Exception chaining)
try {
    // ...
} catch (SQLException e) {
    throw new RuntimeException("DB 오류 발생", e); // cause 포함
}
```

---

## 8. 자주 발생하는 예외 정리

| 예외 | 발생 상황 | 예시 |
|------|-----------|------|
| `NullPointerException` | null 객체 참조 | `str.length()` (str이 null) |
| `ArrayIndexOutOfBoundsException` | 배열 범위 초과 | `arr[10]` (길이 5인 배열) |
| `ClassCastException` | 잘못된 타입 변환 | `(String) obj` (obj가 Integer) |
| `NumberFormatException` | 숫자 변환 실패 | `Integer.parseInt("abc")` |
| `StackOverflowError` | 무한 재귀 | 종료 조건 없는 재귀 메서드 |
| `IllegalArgumentException` | 잘못된 인자 전달 | 음수 크기로 배열 생성 |
| `IllegalStateException` | 객체 상태 불일치 | 닫힌 스트림에서 읽기 |

---

## 9. 모범 사례

```java
// 나쁜 예: 예외를 그냥 삼키기
try {
    // ...
} catch (Exception e) {
    // 아무것도 안 함 (절대 금지)
}

// 나쁜 예: 최상위 Exception으로 무조건 잡기
try {
    // ...
} catch (Exception e) {
    e.printStackTrace(); // 운영 환경에서는 로거 사용
}

// 좋은 예: 구체적인 예외 처리 + 로깅
try {
    // ...
} catch (FileNotFoundException e) {
    log.error("설정 파일을 찾을 수 없습니다: {}", e.getMessage());
    throw new AppConfigException("설정 로드 실패", e);
}
```

**핵심 원칙:**
- 가능한 구체적인 예외 타입을 잡는다
- 예외를 무시(빈 catch)하지 않는다
- 운영 환경에서는 `e.printStackTrace()` 대신 로거를 사용한다
- 예외에 의미 있는 메시지를 담는다
- 자원은 반드시 `try-with-resources`로 닫는다
