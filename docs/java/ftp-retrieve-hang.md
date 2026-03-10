# FTP retrieveFile 무한 대기 현상 해결

## 원인 분석

`ftpClient.retrieveFile()`이 `true/false`를 반환하지 않고 멈추는 원인:

| 원인 | 설명 |
|---|---|
| **Data Connection 타임아웃 미설정** | 데이터 채널 응답 없을 때 무한 대기 |
| **Passive/Active 모드 불일치** | 방화벽이 데이터 포트를 막아 연결 수립 안 됨 |
| **네트워크 단절** | 전송 중 네트워크 끊김, TCP 세션은 살아있지만 데이터 없음 |
| **FTP 서버 응답 지연** | 서버 부하 또는 대용량 파일 처리 지연 |
| **소켓 Read Timeout 미설정** | InputStream 읽기 중 응답 없으면 영구 대기 |

---

## 타임아웃 메서드 기본값

| 메서드 | 기본값 | 의미 |
|---|---|---|
| `setConnectTimeout(ms)` | `0` (무한 대기) | `java.net.Socket` 기본값 상속. 설정 안 하면 TCP connect 단계에서 OS 타임아웃(수분)까지 대기 |
| `setSoTimeout(ms)` | `0` (무한 대기) | `Socket.setSoTimeout(0)` = 타임아웃 없음. 제어 채널 read가 영구 block 가능 |
| `setDataTimeout(Duration)` | `-1` (비활성) | 음수 = 데이터 채널에 별도 타임아웃 없음. `setSoTimeout` 값을 그대로 상속. **두 값 모두 0이면 retrieveFile이 영원히 block** |

> **즉, 아무것도 설정하지 않으면 세 메서드 모두 무한 대기입니다.**
> `setDataTimeout`은 `setSoTimeout`의 fallback이므로, `setSoTimeout`만 설정해도 데이터 채널에 적용되지만
> 별도 분리 제어가 필요하면 `setDataTimeout`을 명시합니다.

---

## 해결 방법 1: Timeout 설정 (가장 먼저 적용)

`retrieveFile`이 내부적으로 소켓 InputStream을 읽으므로,
**`setDataTimeout`** 과 **`setSoTimeout`** 을 반드시 설정해야 합니다.

```java
FTPClient ftpClient = new FTPClient();

// 1. 접속 타임아웃 (connect 단계) - 기본값: 0 (무한)
ftpClient.setConnectTimeout(10_000);       // 10초

// 2. 소켓 Read 타임아웃 (제어 채널 + dataTimeout 미설정 시 데이터 채널에도 적용) - 기본값: 0 (무한)
ftpClient.setSoTimeout(30_000);            // 30초

// 3. 데이터 채널 타임아웃 (retrieveFile 내부 InputStream) - 기본값: -1 (setSoTimeout 상속)
ftpClient.setDataTimeout(Duration.ofSeconds(60)); // 60초

ftpClient.connect(host, port);
ftpClient.login(user, password);
ftpClient.setFileType(FTP.BINARY_FILE_TYPE);
ftpClient.enterLocalPassiveMode();         // 방화벽 환경이면 Passive 모드 권장
```

> `setDataTimeout`은 Apache Commons Net 3.9+ 에서 `Duration` 파라미터를 권장합니다.
> 구버전은 `setDataTimeout(int milliseconds)` 사용.

---

## 해결 방법 2: ExecutorService로 타임아웃 감지 (핵심)

Timeout 설정만으로 해결이 안 될 경우,
`ExecutorService + Future.get(timeout)`으로 `retrieveFile` 호출 자체를 감싸서 강제 중단합니다.

```java
import org.apache.commons.net.ftp.FTP;
import org.apache.commons.net.ftp.FTPClient;

import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.time.Duration;
import java.util.concurrent.*;

public class FtpDownloadService {

    private static final int    CONNECT_TIMEOUT  = 10_000;  // 10초
    private static final int    SO_TIMEOUT       = 30_000;  // 30초
    private static final int    DATA_TIMEOUT_SEC = 60;      // 60초
    private static final long   RETRIEVE_TIMEOUT = 120;     // retrieveFile 최대 대기 (초)

    public void downloadFile(String host, int port,
                             String user, String password,
                             String remotePath, String localPath) throws Exception {

        FTPClient ftpClient = new FTPClient();

        try {
            // ── 접속 및 설정 ──────────────────────────────
            ftpClient.setConnectTimeout(CONNECT_TIMEOUT);
            ftpClient.setSoTimeout(SO_TIMEOUT);
            ftpClient.setDataTimeout(Duration.ofSeconds(DATA_TIMEOUT_SEC));

            ftpClient.connect(host, port);
            ftpClient.login(user, password);
            ftpClient.setFileType(FTP.BINARY_FILE_TYPE);
            ftpClient.enterLocalPassiveMode();

            // ── retrieveFile을 별도 스레드에서 실행 ───────
            ExecutorService executor = Executors.newSingleThreadExecutor();
            FTPClient finalClient = ftpClient;

            Future<Boolean> future = executor.submit(() -> {
                try (OutputStream os = new FileOutputStream(localPath)) {
                    return finalClient.retrieveFile(remotePath, os);
                }
            });

            boolean result;
            try {
                // RETRIEVE_TIMEOUT 초 안에 완료되지 않으면 TimeoutException
                result = future.get(RETRIEVE_TIMEOUT, TimeUnit.SECONDS);
            } catch (TimeoutException e) {
                future.cancel(true);  // 스레드 인터럽트 시도
                throw new IOException(
                    "retrieveFile 타임아웃 (" + RETRIEVE_TIMEOUT + "s 초과): " + remotePath, e
                );
            } catch (ExecutionException e) {
                throw new IOException("retrieveFile 실행 오류: " + e.getCause().getMessage(), e.getCause());
            } finally {
                executor.shutdownNow();
            }

            if (!result) {
                int replyCode = ftpClient.getReplyCode();
                String replyMsg = ftpClient.getReplyString();
                throw new IOException(
                    "retrieveFile 실패 - FTP 응답코드: " + replyCode + ", 메시지: " + replyMsg
                );
            }

            System.out.println("다운로드 완료: " + remotePath + " → " + localPath);

        } finally {
            // ── 반드시 disconnect ─────────────────────────
            if (ftpClient.isConnected()) {
                try { ftpClient.logout(); } catch (IOException ignored) {}
                try { ftpClient.disconnect(); } catch (IOException ignored) {}
            }
        }
    }
}
```

---

## 해결 방법 3: Spring @Async + CompletableFuture

Spring Boot 환경에서 `@Async`를 활용한 방식입니다.

```java
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

@Service
public class FtpAsyncService {

    @Async("ftpTaskExecutor")
    public CompletableFuture<Boolean> retrieveAsync(FTPClient ftpClient,
                                                     String remotePath,
                                                     OutputStream os) {
        try {
            boolean result = ftpClient.retrieveFile(remotePath, os);
            return CompletableFuture.completedFuture(result);
        } catch (IOException e) {
            return CompletableFuture.failedFuture(e);
        }
    }
}
```

```java
// 호출부
@Service
@RequiredArgsConstructor
public class FtpDownloadFacade {

    private final FtpAsyncService ftpAsyncService;

    public void download(FTPClient ftpClient, String remotePath, OutputStream os)
            throws Exception {

        CompletableFuture<Boolean> future = ftpAsyncService.retrieveAsync(ftpClient, remotePath, os);

        boolean result;
        try {
            result = future.get(120, TimeUnit.SECONDS);  // 2분 타임아웃
        } catch (TimeoutException e) {
            future.cancel(true);
            throw new IOException("FTP 다운로드 타임아웃: " + remotePath);
        }

        if (!result) {
            throw new IOException("FTP 다운로드 실패: " + ftpClient.getReplyString());
        }
    }
}
```

```java
// AsyncConfig.java
@Configuration
@EnableAsync
public class AsyncConfig {

    @Bean("ftpTaskExecutor")
    public Executor ftpTaskExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(10);
        executor.setQueueCapacity(50);
        executor.setThreadNamePrefix("ftp-");
        executor.setWaitForTasksToCompleteOnShutdown(false);
        executor.initialize();
        return executor;
    }
}
```

---

## 전체 통합 예제 (Spring Boot Service)

```java
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.net.ftp.FTP;
import org.apache.commons.net.ftp.FTPClient;
import org.apache.commons.net.ftp.FTPReply;
import org.springframework.stereotype.Service;

import java.io.*;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.concurrent.*;

@Slf4j
@Service
public class FtpDownloadService {

    private static final int  CONNECT_TIMEOUT_MS  = 10_000;
    private static final int  SO_TIMEOUT_MS        = 30_000;
    private static final int  DATA_TIMEOUT_SEC     = 60;
    private static final long RETRIEVE_TIMEOUT_SEC = 120;

    public Path download(String host, int port,
                         String user, String password,
                         String remotePath, Path localDir) throws IOException {

        FTPClient ftp = new FTPClient();

        try {
            connect(ftp, host, port);
            login(ftp, user, password);

            Path localFile = localDir.resolve(Path.of(remotePath).getFileName());
            retrieveWithTimeout(ftp, remotePath, localFile);

            log.info("FTP 다운로드 완료: {} → {}", remotePath, localFile);
            return localFile;

        } finally {
            disconnect(ftp);
        }
    }

    // ── private 메서드 ──────────────────────────────────────────────────────

    private void connect(FTPClient ftp, String host, int port) throws IOException {
        ftp.setConnectTimeout(CONNECT_TIMEOUT_MS);
        ftp.setSoTimeout(SO_TIMEOUT_MS);
        ftp.setDataTimeout(Duration.ofSeconds(DATA_TIMEOUT_SEC));

        ftp.connect(host, port);

        int reply = ftp.getReplyCode();
        if (!FTPReply.isPositiveCompletion(reply)) {
            ftp.disconnect();
            throw new IOException("FTP 서버 접속 거부: 응답코드=" + reply);
        }

        ftp.setFileType(FTP.BINARY_FILE_TYPE);
        ftp.enterLocalPassiveMode();
        ftp.setAutodetectUTF8(true);
    }

    private void login(FTPClient ftp, String user, String password) throws IOException {
        if (!ftp.login(user, password)) {
            throw new IOException("FTP 로그인 실패: " + ftp.getReplyString());
        }
    }

    private void retrieveWithTimeout(FTPClient ftp, String remotePath, Path localFile)
            throws IOException {

        Files.createDirectories(localFile.getParent());

        ExecutorService executor = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "ftp-retrieve");
            t.setDaemon(true);
            return t;
        });

        Future<Boolean> future = executor.submit(() -> {
            try (OutputStream os = Files.newOutputStream(localFile)) {
                return ftp.retrieveFile(remotePath, os);
            }
        });

        try {
            boolean result = future.get(RETRIEVE_TIMEOUT_SEC, TimeUnit.SECONDS);

            if (!result) {
                Files.deleteIfExists(localFile);  // 실패 시 불완전 파일 삭제
                throw new IOException(
                    "retrieveFile 반환값 false - FTP 응답: " + ftp.getReplyString()
                );
            }

        } catch (TimeoutException e) {
            future.cancel(true);
            Files.deleteIfExists(localFile);
            throw new IOException(
                String.format("retrieveFile 타임아웃 (%ds 초과): %s", RETRIEVE_TIMEOUT_SEC, remotePath), e
            );
        } catch (ExecutionException e) {
            Files.deleteIfExists(localFile);
            Throwable cause = e.getCause();
            throw new IOException("retrieveFile 실행 중 오류: " + cause.getMessage(), cause);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Files.deleteIfExists(localFile);
            throw new IOException("FTP 다운로드 인터럽트", e);
        } finally {
            executor.shutdownNow();
        }
    }

    private void disconnect(FTPClient ftp) {
        if (ftp.isConnected()) {
            try { ftp.logout(); } catch (IOException ignored) {}
            try { ftp.disconnect(); } catch (IOException ignored) {}
        }
    }
}
```

---

## 타임아웃 설정 정리

| 설정 메서드 | 기본값 | 적용 범위 | 권장값 |
|---|---|---|---|
| `setConnectTimeout(ms)` | `0` (무한) | FTP 서버 TCP 연결 | 10,000ms |
| `setSoTimeout(ms)` | `0` (무한) | 소켓 Read (제어 채널) | 30,000ms |
| `setDataTimeout(Duration)` | `-1` (soTimeout 상속) | 데이터 채널 InputStream Read | 60,000ms |
| `Future.get(timeout, unit)` | - | retrieveFile 전체 실행 | 120s |

---

## retrieveFile 내부 주요 Exception

`retrieveFile`은 내부적으로 아래 순서로 동작합니다.

```
retrieveFile(remote, local)
  ├─ _openDataConnection_()       // 데이터 소켓 연결
  ├─ input = dataSocket.getInputStream()
  ├─ Util.copyStream(input, local) // 실제 데이터 복사 (여기서 주로 발생)
  │     └─ throws CopyStreamException (IOException 래핑)
  └─ completePendingCommand()      // 서버 최종 응답 대기 (226 Transfer complete)
       └─ return FTPReply.isPositiveCompletion(reply)
```

| Exception | 발생 위치 | 원인 |
|---|---|---|
| `CopyStreamException` | `Util.copyStream()` | 데이터 복사 중 I/O 에러. `getTotalBytesTransferred()`로 전송 바이트 확인 가능. 내부 cause에 실제 예외 포함 |
| `SocketTimeoutException` | `copyStream` 내 `read()` | `setSoTimeout` / `setDataTimeout` 초과. **설정된 경우에만 발생** |
| `SocketException: Connection reset` | `copyStream` 내 `read()` | 서버가 TCP 연결을 강제 종료 |
| `SocketException: Broken pipe` | `copyStream` 내 `write()` | 상대방이 소켓을 닫은 상태에서 쓰기 시도 |
| `EOFException` | `copyStream` 내 `read()` | 서버가 데이터 전송 중 연결을 끊음 (파일 중간에 종료) |
| `IOException: Connection timed out` | `read()` / `connect()` | OS 레벨 타임아웃 (TCP keepalive 만료) |

### exception 로그 없이 조용히 종료되는 주요 패턴

```java
// ❌ 패턴 1: catch에서 예외를 삼킴
try {
    ftpClient.retrieveFile(remote, os);
} catch (Exception e) {
    // 아무것도 안 함 → 로그 없이 종료
}

// ❌ 패턴 2: finally에서 disconnect 시 예외가 억제됨
try {
    ftpClient.retrieveFile(remote, os);   // ← 여기서 IOException 발생
} finally {
    ftp.logout();      // ← finally 안에서 또 다른 예외 발생 시
    ftp.disconnect();  //    원래 IOException이 suppressed exception으로 묻힘
}

// ❌ 패턴 3: CopyStreamException의 cause를 확인 안 함
} catch (IOException e) {
    if (e instanceof CopyStreamException cse) {
        // cause를 꺼내지 않으면 "CopyStreamException" 메시지만 보임
        log.error("FTP 오류", cse.getCause()); // ← cause를 명시적으로 로깅해야 함
    }
}
```

---

## 다운로드 중 조용히 종료 - 진단 체크포인트

다운로드가 1초, 10초, 60초 등 일정 시간 후 exception 없이 멈추는 경우 아래 순서로 확인합니다.

### 체크포인트 1: FTP 프로토콜 통신 로그 활성화

`PrintCommandListener`로 FTP 제어 채널 명령/응답을 실시간 출력합니다.
어느 시점에 서버가 응답을 끊는지 확인할 수 있습니다.

```java
// 연결 전에 설정
ftpClient.addProtocolCommandListener(
    new PrintCommandListener(new PrintWriter(System.out), true)
);
```

출력 예:
```
> RETR /remote/file.csv        ← RETR 명령 전송
< 150 Opening data connection  ← 서버가 데이터 채널 오픈
...데이터 전송 중...
< 426 Transfer aborted         ← 서버가 중간에 종료한 경우
```

### 체크포인트 2: CopyStreamListener로 전송 진행 추적

데이터가 얼마나 전송되다 멈추는지 바이트 단위로 추적합니다.

```java
// CopyStreamListener 등록
ftpClient.setCopyStreamListener(new CopyStreamAdapter() {
    @Override
    public void bytesTransferred(long totalBytesTransferred,
                                  int bytesTransferred,
                                  long streamSize) {
        log.debug("FTP 전송 중: {}KB / {}KB",
            totalBytesTransferred / 1024,
            streamSize > 0 ? streamSize / 1024 : "unknown");
    }
});
```

> 전송이 예를 들어 `512KB`에서 멈춘다면, 서버 측에서 특정 크기 이후 연결을 끊거나
> 네트워크 장비(방화벽/로드밸런서)의 idle timeout이 발동된 것입니다.

### 체크포인트 3: retrieveFile 반환 후 replyCode 확인

`retrieveFile`이 `false`를 반환하는 경우(exception 없이)는 반드시 응답코드를 로깅합니다.

```java
boolean result = ftpClient.retrieveFile(remotePath, os);
int replyCode = ftpClient.getReplyCode();
String replyMsg = ftpClient.getReplyString();

log.info("retrieveFile 결과: result={}, replyCode={}, replyMsg={}", result, replyCode, replyMsg);

if (!result) {
    // 주요 FTP 응답코드
    // 426: Connection closed, transfer aborted (서버가 전송 중단)
    // 450: Requested file action not taken (파일 잠김)
    // 550: File unavailable (권한 없음, 파일 없음)
    throw new IOException("FTP 다운로드 실패: [" + replyCode + "] " + replyMsg);
}
```

### 체크포인트 4: CopyStreamException cause 분리 로깅

`retrieveFile`이 `CopyStreamException`을 던지는 경우,
cause를 명시적으로 꺼내지 않으면 원인 파악이 어렵습니다.

```java
try {
    boolean result = ftpClient.retrieveFile(remotePath, os);
} catch (CopyStreamException e) {
    log.error("FTP 전송 중단 - 전송 바이트: {}KB, 원인: {}",
        e.getTotalBytesTransferred() / 1024,
        e.getCause() != null ? e.getCause().getClass().getSimpleName() + ": " + e.getCause().getMessage()
                              : e.getMessage());
    throw e;
} catch (SocketTimeoutException e) {
    log.error("FTP 데이터 채널 타임아웃 (setSoTimeout / setDataTimeout 초과)");
    throw e;
} catch (SocketException e) {
    log.error("FTP 소켓 오류 (서버 강제 종료 또는 네트워크 단절): {}", e.getMessage());
    throw e;
} catch (IOException e) {
    log.error("FTP 다운로드 IOException: {}", e.getMessage(), e);
    throw e;
}
```

### 체크포인트 5: 네트워크 장비 Idle Timeout 확인

방화벽/로드밸런서/NAT 장비가 일정 시간 동안 데이터 흐름이 없으면
TCP 세션을 강제로 끊는 경우가 있습니다. 이 경우 FTP 클라이언트는 예외 없이
다음 `read()`에서 `Connection reset` 또는 `EOF`를 받습니다.

```java
// TCP KeepAlive 활성화로 idle 세션 유지
ftpClient.setKeepAlive(true);

// 또는 FTP NOOP 명령으로 주기적으로 세션 유지 (별도 스레드)
ScheduledExecutorService keepAlive = Executors.newSingleThreadScheduledExecutor();
keepAlive.scheduleAtFixedRate(() -> {
    try {
        ftpClient.sendNoOp();   // NOOP 전송 → 서버가 200 응답 → 세션 유지
        log.debug("FTP NOOP sent");
    } catch (IOException e) {
        log.warn("FTP NOOP 실패: {}", e.getMessage());
    }
}, 30, 30, TimeUnit.SECONDS);  // 30초마다 전송
```

> `sendNoOp()`는 대용량 파일 다운로드 중에는 제어 채널이 blocking될 수 있으므로
> NOOP 대신 `setDataTimeout`을 충분히 설정하는 것을 우선 권장합니다.

### 체크포인트 6: finally 블록 예외 억제 방지

```java
// ❌ 잘못된 구조: retrieveFile 예외가 finally 예외에 묻힘
try {
    ftpClient.retrieveFile(remote, os);
} finally {
    ftp.logout();     // 여기서 예외 발생 시 원래 예외 suppressed
    ftp.disconnect();
}

// ✅ 올바른 구조
IOException retrieveException = null;
try {
    ftpClient.retrieveFile(remote, os);
} catch (IOException e) {
    retrieveException = e;
    log.error("FTP retrieveFile 실패: {}", e.getMessage(), e);
} finally {
    try { ftp.logout(); } catch (IOException ignored) {}
    try { ftp.disconnect(); } catch (IOException ignored) {}
}
if (retrieveException != null) throw retrieveException;
```

---

## 주의사항

**`future.cancel(true)`는 인터럽트만 시도**

`retrieveFile`은 내부적으로 blocking I/O를 사용하므로 `cancel(true)`로도 즉시 중단되지 않을 수 있습니다.
이 경우 FTP 소켓 자체를 닫아야 스레드가 `IOException`을 받고 종료됩니다.

```java
} catch (TimeoutException e) {
    future.cancel(true);
    // 소켓 강제 종료로 blocking I/O 해제
    try { ftp.abort(); } catch (IOException ignored) {}
    try { ftp.disconnect(); } catch (IOException ignored) {}
    Files.deleteIfExists(localFile);
    throw new IOException("retrieveFile 타임아웃", e);
}
```

**Passive 모드 우선 사용**

방화벽 환경에서 Active 모드는 데이터 채널 수립이 실패해 `retrieveFile`이 무한 대기합니다.

```java
ftp.enterLocalPassiveMode();  // 방화벽 환경 필수
```

**불완전 파일 반드시 삭제**

타임아웃/실패 시 로컬에 0byte 또는 불완전 파일이 남으므로 catch 블록에서 삭제 처리합니다.

```java
Files.deleteIfExists(localFile);
```
