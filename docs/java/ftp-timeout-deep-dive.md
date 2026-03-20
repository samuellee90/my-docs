# FTPClient 타임아웃 파라미터 심층 분석

> Apache Commons Net `FTPClient` 기준.
> `retrieveFile` 내부 **read source buffer** 단계에서 스레드가 hang 걸리는 원인과 직접 관련된 5개 파라미터를 기본값·정의·출처 기준으로 정리합니다.

---

## retrieveFile 내부 동작 흐름

```
ftpClient.retrieveFile(remote, outputStream)
  ├─ _openDataConnection_()         ← 데이터 소켓 연결 (setDataTimeout 적용 시점)
  ├─ dataSocket.getInputStream()
  ├─ Util.copyStream(input, output) ← [hang 발생 지점] InputStream.read() 블로킹
  │     └─ throws CopyStreamException
  └─ completePendingCommand()        ← 제어 채널에서 226 응답 대기 (setSoTimeout 적용)
```

> `Util.copyStream()` 내부의 `InputStream.read()`가 **타임아웃 없이 호출**되면 영구 block됩니다.

---

## 파라미터 상세 정리

### 1. `setConnectTimeout(int ms)`

| 항목 | 내용 |
|---|---|
| **출처** | `org.apache.commons.net.SocketClient` |
| **기본값** | `0` (OS 기본 connect 타임아웃에 위임) |
| **정의** | `Socket.connect(SocketAddress endpoint, int timeout)` 호출 시 전달되는 타임아웃. TCP 3-way handshake 완료 전 타임아웃 발생 시 `SocketTimeoutException` 던짐. |
| **적용 시점** | `ftpClient.connect()` 내부 |
| **hang 탈출 여부** | ❌ 데이터 전송 중 hang과 무관. connect 단계에만 적용. |

```java
// SocketClient 내부 필드
private int connectTimeout = 0; // default: OS 위임 (사실상 무한)

// 적용 코드
socket.connect(new InetSocketAddress(host, port), connectTimeout);
```

---

### 2. `setDefaultTimeout(int ms)`

| 항목 | 내용 |
|---|---|
| **출처** | `org.apache.commons.net.SocketClient` |
| **기본값** | `0` (무한 대기) |
| **정의** | 소켓 생성 직후 `socket.setSoTimeout(defaultTimeout)`을 적용하는 초기 SO_TIMEOUT. `connect()` 호출 → `_connectAction_()` 내부에서 처리됨. 이후 `setSoTimeout()`으로 덮어쓸 수 있음. |
| **적용 시점** | `connect()` 호출 시 소켓 생성 직후 (connect 단계 포함) |
| **hang 탈출 여부** | ⚠️ 제어 채널에 적용되므로 `completePendingCommand()` hang은 탈출 가능. 데이터 채널에는 적용 안 됨. |

```java
// SocketClient 내부 필드
private int defaultTimeout = 0;

// 소켓 생성 시 적용
_socket_.setSoTimeout(defaultTimeout);
```

> `setConnectTimeout`과 별개입니다.
> `setDefaultTimeout`은 **SO_TIMEOUT** (read 타임아웃),
> `setConnectTimeout`은 **connect 단계** 타임아웃입니다.

---

### 3. `setSoTimeout(int ms)`

| 항목 | 내용 |
|---|---|
| **출처** | `org.apache.commons.net.SocketClient` |
| **기본값** | `0` (무한 대기) |
| **정의** | 이미 연결된 제어 채널 소켓에 `socket.setSoTimeout(soTimeout)` 적용. `connect()` 이후에만 호출 가능. 제어 채널의 모든 read 작업에 적용됨. |
| **적용 시점** | `connect()` 완료 후 수동 호출 |
| **hang 탈출 여부** | ⚠️ `completePendingCommand()` 등 제어 채널 hang 탈출 가능. **데이터 채널은 별도 설정 필요.** |

```java
// SocketClient 내부 필드
private int soTimeout = 0;

// connect() 이후 적용
_socket_.setSoTimeout(soTimeout);
// 타임아웃 초과 시 → SocketTimeoutException 발생
```

---

### 4. `setDataTimeout(Duration d)`

| 항목 | 내용 |
|---|---|
| **출처** | `org.apache.commons.net.ftp.FTPClient` |
| **기본값** | `Duration.ofMillis(-1)` (음수 = 타임아웃 미설정, 무한 대기) |
| **정의** | `_openDataConnection_()` 내에서 데이터 채널 소켓 생성 직후 SO_TIMEOUT을 적용. 음수(-1)이면 조건 미충족으로 **타임아웃을 설정하지 않음** (soTimeout 상속 없음). |
| **적용 시점** | `retrieveFile()` 내부 → `_openDataConnection_()` 호출 시 |
| **hang 탈출 여부** | ✅ **가장 직접적.** 데이터 채널 `InputStream.read()`에 직접 적용 → 초과 시 `SocketTimeoutException` → `CopyStreamException`으로 래핑 → `retrieveFile`이 `IOException`으로 throw. |

```java
// FTPClient 내부 필드
private Duration dataTimeout = Duration.ofMillis(-1);

// _openDataConnection_() 내부 적용 로직
final int soTimeoutMillis = DurationUtils.toMillisInt(dataTimeout);
if (soTimeoutMillis >= 0) {         // ← 음수면 이 블록 실행 안 됨
    server.setSoTimeout(soTimeoutMillis);
}
// → dataTimeout이 -1이면 데이터 소켓은 타임아웃 없음 (무한 대기)
```

> **중요**: `dataTimeout`이 음수일 때 `soTimeout`이 자동 상속되지 않습니다.
> 데이터 채널 hang을 방지하려면 **반드시 명시적으로 설정해야 합니다.**

---

### 5. `setControlKeepAliveTimeout(Duration d)`

| 항목 | 내용 |
|---|---|
| **출처** | `org.apache.commons.net.ftp.FTPClient` |
| **기본값** | `Duration.ZERO` (0 = 비활성) |
| **정의** | 데이터 전송 중 제어 채널에 **NOOP 명령을 전송하는 간격**. 0이면 NOOP을 보내지 않음. 대용량 파일 전송 시 방화벽/서버의 idle timeout으로 제어 채널 세션이 끊기는 것을 방지. |
| **적용 시점** | `retrieveFile()` 내부 데이터 전송 루프 중 |
| **hang 탈출 여부** | ❌ hang 탈출 목적이 아님. **세션 유지 목적.** 제어 채널이 끊기지 않도록 예방하는 역할. |

```java
// FTPClient 내부 필드
private Duration controlKeepAliveTimeout = Duration.ZERO;

// 데이터 전송 중 NOOP 전송 로직
if (!controlKeepAliveTimeout.isZero() &&
    System.currentTimeMillis() - lastNoop > controlKeepAliveTimeout.toMillis()) {
    sendNoOp();   // NOOP → 서버 응답 200 → 제어 세션 유지
    lastNoop = System.currentTimeMillis();
}
```

---

## 5개 파라미터 비교 요약표

| 파라미터 | 출처 클래스 | 기본값 | 적용 채널 | hang 탈출 | 발생 예외 |
|---|---|---|---|---|---|
| `setConnectTimeout` | `SocketClient` | `0` (무한) | TCP connect 단계 | ❌ | `SocketTimeoutException` (connect 시) |
| `setDefaultTimeout` | `SocketClient` | `0` (무한) | 제어 채널 (소켓 생성 직후) | ⚠️ 부분 | `SocketTimeoutException` |
| `setSoTimeout` | `SocketClient` | `0` (무한) | 제어 채널 (connect 이후) | ⚠️ 부분 | `SocketTimeoutException` |
| **`setDataTimeout`** | **`FTPClient`** | **`-1` (무한)** | **데이터 채널** | **✅ 직접** | **`SocketTimeoutException` → `CopyStreamException`** |
| `setControlKeepAliveTimeout` | `FTPClient` | `Duration.ZERO` (비활성) | 제어 채널 NOOP | ❌ | - (예외 미발생) |

---

## hang 탈출 메커니즘 상세

### `setDataTimeout`이 hang을 탈출시키는 경로

```
setDataTimeout(Duration.ofSeconds(60)) 설정
  → _openDataConnection_() 내에서 dataSocket.setSoTimeout(60_000) 적용
  → Util.copyStream() 내부 InputStream.read() 호출
  → 60초 동안 데이터 없음
  → java.net.SocketTimeoutException: Read timed out
  → org.apache.commons.net.io.CopyStreamException (cause: SocketTimeoutException)
  → retrieveFile()이 IOException으로 throw
  → 스레드가 hang 상태에서 벗어남
```

### 예외 처리 코드

```java
FTPClient ftpClient = new FTPClient();

// hang 탈출을 위한 핵심 설정
ftpClient.setConnectTimeout(10_000);                     // 10초 - connect 단계
ftpClient.setSoTimeout(30_000);                          // 30초 - 제어 채널
ftpClient.setDataTimeout(Duration.ofSeconds(60));        // 60초 - 데이터 채널 (hang 탈출 핵심)

// 세션 유지 (예방)
ftpClient.setControlKeepAliveTimeout(Duration.ofSeconds(30));

ftpClient.connect(host, port);
ftpClient.login(user, password);
ftpClient.setFileType(FTP.BINARY_FILE_TYPE);
ftpClient.enterLocalPassiveMode();

try (OutputStream os = new FileOutputStream(localPath)) {
    boolean result = ftpClient.retrieveFile(remotePath, os);

    if (!result) {
        throw new IOException("FTP 다운로드 실패: " + ftpClient.getReplyString());
    }

} catch (CopyStreamException e) {
    // ← setDataTimeout 초과 시 발생하는 예외
    // e.getCause() == SocketTimeoutException
    log.error("데이터 전송 중단 - 전송 바이트: {}KB, 원인: {}",
        e.getTotalBytesTransferred() / 1024,
        e.getCause() != null ? e.getCause().getMessage() : e.getMessage());
    throw e;

} catch (SocketTimeoutException e) {
    // ← setSoTimeout / setDefaultTimeout 초과 시 발생 (제어 채널)
    log.error("소켓 타임아웃 (제어 채널): {}", e.getMessage());
    throw e;

} catch (IOException e) {
    log.error("FTP 다운로드 실패: {}", e.getMessage(), e);
    throw e;
}
```

---

## 파라미터별 출처 (Apache Commons Net 소스코드)

| 파라미터 | 소스 파일 | 참조 |
|---|---|---|
| `setConnectTimeout` | `SocketClient.java` | [GitHub - SocketClient](https://github.com/apache/commons-net/blob/master/src/main/java/org/apache/commons/net/SocketClient.java) |
| `setDefaultTimeout` | `SocketClient.java` | [GitHub - SocketClient](https://github.com/apache/commons-net/blob/master/src/main/java/org/apache/commons/net/SocketClient.java) |
| `setSoTimeout` | `SocketClient.java` | [GitHub - SocketClient](https://github.com/apache/commons-net/blob/master/src/main/java/org/apache/commons/net/SocketClient.java) |
| `setDataTimeout` | `FTPClient.java` | [GitHub - FTPClient](https://github.com/apache/commons-net/blob/master/src/main/java/org/apache/commons/net/ftp/FTPClient.java) |
| `setControlKeepAliveTimeout` | `FTPClient.java` | [GitHub - FTPClient](https://github.com/apache/commons-net/blob/master/src/main/java/org/apache/commons/net/ftp/FTPClient.java) |

> Apache Commons Net 3.9.0 이상 기준. `setDataTimeout(int ms)` (int 버전)은 deprecated.
