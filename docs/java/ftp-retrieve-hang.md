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

## 해결 방법 1: Timeout 설정 (가장 먼저 적용)

`retrieveFile`이 내부적으로 소켓 InputStream을 읽으므로,
**`setDataTimeout`** 과 **`setSoTimeout`** 을 반드시 설정해야 합니다.

```java
FTPClient ftpClient = new FTPClient();

// 1. 접속 타임아웃 (connect 단계)
ftpClient.setConnectTimeout(10_000);       // 10초

// 2. 소켓 Read 타임아웃 (데이터 수신 중 응답 없을 때)
ftpClient.setSoTimeout(30_000);            // 30초

// 3. 데이터 채널 타임아웃 (retrieveFile 내부 InputStream)
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

| 설정 메서드 | 적용 범위 | 권장값 |
|---|---|---|
| `setConnectTimeout(ms)` | FTP 서버 TCP 연결 | 10,000ms |
| `setSoTimeout(ms)` | 소켓 Read (제어 채널) | 30,000ms |
| `setDataTimeout(Duration)` | 데이터 채널 InputStream Read | 60,000ms |
| `Future.get(timeout, unit)` | retrieveFile 전체 실행 | 120s |

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
