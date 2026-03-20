# FTPClient retrieveFile hang - setDataTimeout 누락 원인 분석

## 현상

아래 타임아웃을 설정했음에도 `ftpClient.retrieveFile()` 중
`InputStream.read()` 단계에서 스레드가 무한 대기 상태에 빠짐.

```java
ftpClient.setConnectTimeout(7000);   // 7초
ftpClient.setDefaultTimeout(7000);   // 7초
ftpClient.setSoTimeout(10000);       // 10초

ftpClient.connect(host, port);
ftpClient.login(user, password);
ftpClient.retrieveFile(remotePath, outputStream); // ← InputStream.read() hang
```

---

## 원인

### FTP 채널 구조

FTPClient는 내부적으로 **두 개의 독립된 소켓**을 사용합니다.

```
[제어 채널 소켓]  ← setDefaultTimeout / setSoTimeout 적용 대상
  - FTP 명령/응답 (RETR, 226 Transfer complete 등)
  - connect() 시 생성

[데이터 채널 소켓]  ← setDataTimeout 적용 대상
  - 실제 파일 데이터 송수신
  - retrieveFile() 호출 시 _openDataConnection_() 내부에서 별도 생성
```

> 두 소켓은 완전히 별개입니다.
> **제어 채널 타임아웃 설정은 데이터 채널에 전혀 영향을 주지 않습니다.**

---

### 설정된 3개 파라미터가 데이터 채널에 미치는 영향

| 파라미터 | 적용 소켓 | 데이터 채널 영향 |
|---|---|---|
| `setConnectTimeout(7000)` | TCP connect 단계 (제어 채널) | ❌ 없음 |
| `setDefaultTimeout(7000)` | 제어 채널 소켓 생성 직후 SO_TIMEOUT | ❌ 없음 |
| `setSoTimeout(10000)` | 제어 채널 소켓 SO_TIMEOUT (connect 이후) | ❌ 없음 |
| `setDataTimeout` | **데이터 채널 소켓 SO_TIMEOUT** | ✅ **미설정 상태** |

### setDataTimeout 미설정 시 내부 동작

`_openDataConnection_()` 내부 코드:

```java
// FTPClient._openDataConnection_() 발췌
final int soTimeoutMillis = DurationUtils.toMillisInt(dataTimeout); // dataTimeout = -1 → -1
if (soTimeoutMillis >= 0) {     // -1 >= 0 → false → 이 블록 실행 안 됨
    server.setSoTimeout(soTimeoutMillis);
}
// → 데이터 소켓에 SO_TIMEOUT이 설정되지 않음
// → InputStream.read() 호출 시 무한 대기
```

`setDataTimeout` 기본값은 `Duration.ofMillis(-1)` (음수).
음수면 타임아웃 미설정 조건이 skip되어 **데이터 소켓의 SO_TIMEOUT = 0 (무한 대기)** 상태가 됩니다.

---

### 타임아웃 설정 시점 정리

```
ftpClient.setConnectTimeout(7000)    ─┐
ftpClient.setDefaultTimeout(7000)    ─┤ connect() 이전에 설정
                                      │
ftpClient.connect(host, port)         │
  └─ 제어 채널 소켓 생성              │
  └─ defaultTimeout 적용 (SO_TIMEOUT = 7000)
  └─ TCP connect (connectTimeout = 7000 제한)

ftpClient.setSoTimeout(10000)         │ connect() 이후
  └─ 제어 채널 소켓 SO_TIMEOUT = 10000으로 덮어씀

ftpClient.retrieveFile(remote, os)
  └─ _openDataConnection_()
       └─ 데이터 채널 소켓 별도 생성  ← 이 시점에 dataTimeout 적용
       └─ dataTimeout = -1 → SO_TIMEOUT 미설정 → 무한 대기 ← 문제 지점

  └─ Util.copyStream(dataInputStream, os)
       └─ dataInputStream.read()      ← hang 발생
```

---

## 조치 방안

### 즉시 조치: `setDataTimeout` 추가

`connect()` **이전**에 설정합니다.

```java
ftpClient.setConnectTimeout(7000);
ftpClient.setDefaultTimeout(7000);
ftpClient.setSoTimeout(10000);
ftpClient.setDataTimeout(Duration.ofSeconds(60));  // ← 추가

ftpClient.connect(host, port);
ftpClient.login(user, password);
ftpClient.retrieveFile(remotePath, outputStream);
```

`setDataTimeout`이 적용되면 데이터 채널 read 타임아웃 초과 시:

```
SocketTimeoutException: Read timed out
  → CopyStreamException (cause: SocketTimeoutException)
    → retrieveFile()이 IOException throw
      → 스레드 hang 탈출
```

### `setDataTimeout` 권장값 기준

| 상황 | 권장값 |
|---|---|
| 소용량 파일 (수 MB 이하) | `Duration.ofSeconds(30)` |
| 일반 파일 | `Duration.ofSeconds(60)` |
| 대용량 파일 (수백 MB 이상) | `Duration.ofSeconds(120)` 이상 |
| 네트워크 불안정 환경 | `Duration.ofSeconds(120)` + keepAlive 병행 |

> 파일 크기에 비례해서 설정합니다.
> 너무 짧으면 정상 전송 중에도 타임아웃이 발생할 수 있습니다.

---

### 예외 처리

`setDataTimeout` 설정 후 hang 탈출 시 발생하는 예외를 명시적으로 처리합니다.

```java
try (OutputStream os = new FileOutputStream(localPath)) {
    boolean result = ftpClient.retrieveFile(remotePath, os);
    if (!result) {
        throw new IOException("FTP 다운로드 실패: " + ftpClient.getReplyString());
    }
} catch (CopyStreamException e) {
    // setDataTimeout 초과 → InputStream.read() SocketTimeoutException → 여기로 전달
    Throwable cause = e.getCause();
    if (cause instanceof SocketTimeoutException) {
        log.error("데이터 채널 타임아웃 - 전송 바이트: {}KB", e.getTotalBytesTransferred() / 1024);
    } else {
        log.error("데이터 전송 중단 - 원인: {}", cause != null ? cause.getMessage() : e.getMessage());
    }
    throw new IOException("FTP 파일 전송 실패", e);
} catch (SocketTimeoutException e) {
    // setSoTimeout 초과 → 제어 채널 타임아웃
    log.error("제어 채널 타임아웃 (completePendingCommand 등): {}", e.getMessage());
    throw e;
} catch (IOException e) {
    log.error("FTP IOException: {}", e.getMessage(), e);
    throw e;
}
```

---

## 최종 권장 설정

```java
FTPClient ftpClient = new FTPClient();

ftpClient.setConnectTimeout(7_000);                    // TCP connect: 7초
ftpClient.setDefaultTimeout(7_000);                    // 소켓 생성 직후 SO_TIMEOUT
ftpClient.setSoTimeout(10_000);                        // 제어 채널 SO_TIMEOUT: 10초
ftpClient.setDataTimeout(Duration.ofSeconds(60));      // 데이터 채널 SO_TIMEOUT: 60초 ← 필수

ftpClient.connect(host, port);
ftpClient.login(user, password);
ftpClient.setFileType(FTP.BINARY_FILE_TYPE);
ftpClient.enterLocalPassiveMode();
```

> `setDataTimeout`은 `setConnectTimeout` / `setSoTimeout`과 **독립적**입니다.
> 다른 타임아웃을 아무리 설정해도 `setDataTimeout`이 없으면 데이터 채널 hang은 방지할 수 없습니다.
