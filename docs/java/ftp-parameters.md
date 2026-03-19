# FTPClient 파라미터 전체 정리 (Apache Commons Net)

> Apache Commons Net `FTPClient` 기준. 장애 원인이었던 `retrieveFile` 무한 대기는
> **타임아웃 미설정**이 핵심이며, 아래 파라미터 중 `setConnectTimeout` / `setSoTimeout` / `setDataTimeout`이 직접 관련됩니다.

---

## 1. 타임아웃 파라미터

| 메서드 | 기본값 | 적용 범위 | 권장값 |
|---|---|---|---|
| `setConnectTimeout(int ms)` | `0` (무한 대기) | TCP connect 단계 | `10_000` (10초) |
| `setSoTimeout(int ms)` | `0` (무한 대기) | 제어 채널 소켓 read / `setDataTimeout` 미설정 시 데이터 채널에도 적용 | `30_000` (30초) |
| `setDataTimeout(Duration d)` | `-1` (비활성 → soTimeout 상속) | 데이터 채널 InputStream read (`retrieveFile` 내부) | `Duration.ofSeconds(60)` |
| `setDefaultTimeout(int ms)` | `0` (무한 대기) | `connect()` 호출 전 소켓 생성 시 소켓 레벨 타임아웃 (setConnectTimeout과 별개) | `10_000` |

> **주의**: 세 타임아웃 모두 기본값이 `0` 또는 `-1`이므로 아무것도 설정하지 않으면 `retrieveFile`은 영구 block됩니다.
> `setDataTimeout`은 `setSoTimeout`의 fallback — 별도 제어가 필요할 때만 명시합니다.

---

## 2. 연결 파라미터

| 메서드 | 기본값 | 설명 | 권장값 |
|---|---|---|---|
| `setDefaultPort(int port)` | `21` | FTP 표준 포트 | 서버 설정에 따라 변경 |
| `setProxy(Proxy proxy)` | `null` (직접 연결) | SOCKS / HTTP 프록시 설정 | 프록시 환경에서 명시 |
| `setRemoteVerificationEnabled(boolean)` | `true` | 데이터 연결 원격 IP 검증 (보안용) | `true` 유지; NAT 환경에서만 `false` 고려 |

---

## 3. 데이터 전송 모드

| 메서드 | 기본값 | 선택지 | 권장값 |
|---|---|---|---|
| `setFileType(int type)` | `FTP.ASCII_FILE_TYPE` | `ASCII_FILE_TYPE` / `BINARY_FILE_TYPE` / `EBCDIC_FILE_TYPE` | **`FTP.BINARY_FILE_TYPE`** (바이너리 파일 필수) |
| `setFileStructure(int structure)` | `FTP.FILE_STRUCTURE` | `FILE_STRUCTURE` / `RECORD_STRUCTURE` / `PAGE_STRUCTURE` | `FTP.FILE_STRUCTURE` (변경 불필요) |
| `setFileTransferMode(int mode)` | `FTP.STREAM_TRANSFER_MODE` | `STREAM_TRANSFER_MODE` / `BLOCK_TRANSFER_MODE` / `COMPRESSED_TRANSFER_MODE` | `FTP.STREAM_TRANSFER_MODE` (변경 불필요) |

> `retrieveFile`로 이진 파일(이미지·압축 파일 등)을 내려받을 때 `BINARY_FILE_TYPE`을 반드시 설정해야 합니다.
> ASCII 모드에서는 개행 변환으로 파일이 깨집니다.

---

## 4. Passive / Active 모드

| 메서드 | 설명 | 권장 |
|---|---|---|
| `enterLocalPassiveMode()` | 클라이언트가 PASV 요청 → 서버가 데이터 포트 오픈 | **방화벽·NAT 환경에서 필수** |
| `enterLocalActiveMode()` | 서버가 클라이언트 포트로 역접속 (기본 동작) | 방화벽 없는 내부망에서만 사용 |
| `enterRemotePassiveMode()` | 서버→서버 FXP 전송용 | 일반 사용 안 함 |
| `setPassiveLocalIPAddress(String ip)` | Passive 모드 데이터 소켓 바인드 IP | 멀티홈 서버에서 명시 |
| `setPassiveNatWorkaround(boolean)` | `true` | PASV 응답 IP를 제어 채널 서버 IP로 교체 | NAT 환경에서 `true` (기본값) |
| `setReportActiveExternalIPAddress(String ip)` | Active 모드 PORT 명령에 사용할 외부 IP | Active 모드 + NAT 환경에서 명시 |

---

## 5. 소켓 버퍼 파라미터

| 메서드 | 기본값 | 설명 | 권장값 |
|---|---|---|---|
| `setBufferSize(int size)` | `0` (OS 기본 소켓 버퍼) | 데이터 채널 소켓 수신 버퍼 크기 (bytes) | 대용량 파일: `1_048_576` (1MB) |
| `setSendBufferSize(int size)` | `0` (OS 기본) | 소켓 송신 버퍼 크기 | 업로드 최적화 시 `1_048_576` |
| `setReceiveBufferSize(int size)` | `0` (OS 기본) | 소켓 수신 버퍼 크기 | 다운로드 최적화 시 `1_048_576` |

---

## 6. 제어 채널 Keep-Alive 파라미터

| 메서드 | 기본값 | 설명 | 권장값 |
|---|---|---|---|
| `setKeepAlive(boolean)` | `false` | TCP 레벨 keepalive 활성화 | `true` (장시간 전송 환경) |
| `setControlKeepAliveTimeout(Duration d)` | `Duration.ofSeconds(0)` (비활성) | 데이터 전송 중 제어 채널에 NOOP 전송 간격 | `Duration.ofSeconds(30)` |
| `setControlKeepAliveReplyTimeout(Duration d)` | `Duration.ofMillis(1000)` | NOOP 응답 대기 최대 시간 | `Duration.ofSeconds(5)` |

> **주의**: `setControlKeepAliveTimeout`은 대용량 파일 전송 중 제어 채널 세션 유지를 위해 사용합니다.
> 단, 제어 채널 자체가 blocking될 수 있으므로 `setDataTimeout`을 충분히 설정하는 것이 우선입니다.

---

## 7. 인코딩 파라미터

| 메서드 | 기본값 | 설명 | 권장값 |
|---|---|---|---|
| `setControlEncoding(String charset)` | `"ISO-8859-1"` | FTP 제어 채널 명령/응답 인코딩 | 한글 경로: `"UTF-8"` |
| `setAutodetectUTF8(boolean)` | `false` | 서버의 UTF8 Feature 감지 후 자동으로 UTF-8 전환 | `true` (한글 파일명 환경) |

---

## 8. 응답 파싱 파라미터

| 메서드 | 기본값 | 설명 | 권장값 |
|---|---|---|---|
| `setStrictReplyParsing(boolean)` | `true` | RFC 959 응답 형식 엄격 파싱 | `true` 유지; 비표준 서버 연동 시 `false` |
| `setListHiddenFiles(boolean)` | `false` | `listFiles()` 시 숨김 파일 포함 | 필요 시 `true` |
| `setUseEPSVwithIPv4(boolean)` | `false` | IPv4에서도 EPSV 사용 | IPv4 환경에서는 `false` 유지 |

---

## 9. 전송 진행 모니터링

| 메서드 | 기본값 | 설명 |
|---|---|---|
| `setCopyStreamListener(CopyStreamListener)` | `null` | 데이터 전송 바이트 수 콜백 수신. 진행률·속도 계산에 사용 |
| `addProtocolCommandListener(ProtocolCommandListener)` | - | FTP 제어 채널 명령/응답 실시간 로깅 (`PrintCommandListener`) |

```java
// 전송 진행 추적
ftpClient.setCopyStreamListener(new CopyStreamAdapter() {
    @Override
    public void bytesTransferred(long total, int chunk, long streamSize) {
        log.debug("전송 중: {}KB / {}KB", total / 1024,
            streamSize > 0 ? streamSize / 1024 : "unknown");
    }
});

// 제어 채널 로그 (디버깅용)
ftpClient.addProtocolCommandListener(
    new PrintCommandListener(new PrintWriter(System.out), true)
);
```

---

## 10. 권장 설정 전체 템플릿

```java
FTPClient ftp = new FTPClient();

// ── 타임아웃 ────────────────────────────────────
ftp.setConnectTimeout(10_000);                        // TCP connect: 10초
ftp.setSoTimeout(30_000);                             // 제어 채널 read: 30초
ftp.setDataTimeout(Duration.ofSeconds(60));           // 데이터 채널 read: 60초

// ── 제어 채널 Keep-Alive ─────────────────────────
ftp.setKeepAlive(true);
ftp.setControlKeepAliveTimeout(Duration.ofSeconds(30));
ftp.setControlKeepAliveReplyTimeout(Duration.ofSeconds(5));

// ── 소켓 버퍼 (대용량 파일 최적화) ──────────────
ftp.setBufferSize(1_048_576);                         // 1MB

// ── 인코딩 ──────────────────────────────────────
ftp.setControlEncoding("UTF-8");
ftp.setAutodetectUTF8(true);

// ── 연결 & 로그인 ────────────────────────────────
ftp.connect(host, port);
if (!FTPReply.isPositiveCompletion(ftp.getReplyCode())) {
    ftp.disconnect();
    throw new IOException("FTP 서버 접속 거부: " + ftp.getReplyCode());
}
ftp.login(user, password);

// ── 전송 설정 ────────────────────────────────────
ftp.setFileType(FTP.BINARY_FILE_TYPE);               // 바이너리 필수
ftp.enterLocalPassiveMode();                          // 방화벽 환경 필수
ftp.setRemoteVerificationEnabled(true);

// ── (선택) 진행 모니터링 ─────────────────────────
ftp.setCopyStreamListener(new CopyStreamAdapter() {
    @Override
    public void bytesTransferred(long total, int chunk, long streamSize) {
        log.debug("FTP 전송: {}KB", total / 1024);
    }
});
```

---

## 11. 파라미터 요약표

| 카테고리 | 파라미터 | 기본값 | 권장값 |
|---|---|---|---|
| 타임아웃 | `setConnectTimeout` | `0` (무한) | `10_000ms` |
| 타임아웃 | `setSoTimeout` | `0` (무한) | `30_000ms` |
| 타임아웃 | `setDataTimeout` | `-1` (soTimeout 상속) | `60s` |
| 타임아웃 | `setDefaultTimeout` | `0` (무한) | `10_000ms` |
| 전송 모드 | `setFileType` | `ASCII` | `BINARY_FILE_TYPE` |
| 연결 모드 | `enterLocalPassiveMode` | Active 모드 | **Passive 필수** (방화벽 환경) |
| Keep-Alive | `setKeepAlive` | `false` | `true` |
| Keep-Alive | `setControlKeepAliveTimeout` | `0` (비활성) | `30s` |
| Keep-Alive | `setControlKeepAliveReplyTimeout` | `1000ms` | `5s` |
| 버퍼 | `setBufferSize` | `0` (OS 기본) | `1MB` (대용량) |
| 인코딩 | `setControlEncoding` | `ISO-8859-1` | `UTF-8` (한글 환경) |
| 인코딩 | `setAutodetectUTF8` | `false` | `true` |
| NAT | `setPassiveNatWorkaround` | `true` | `true` 유지 |
| 검증 | `setRemoteVerificationEnabled` | `true` | `true` 유지 |
