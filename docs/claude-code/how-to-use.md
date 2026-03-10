# Claude Code 사용 가이드

> Claude Code는 Anthropic의 공식 CLI 도구로, 터미널에서 AI 코딩 어시스턴트를 사용할 수 있습니다.

## 설치

```bash
npm install -g @anthropic-ai/claude-code
```

## 기본 실행

```bash
# 현재 디렉토리에서 실행
claude

# 특정 디렉토리에서 실행
claude --cwd /path/to/project
```

---

## 주요 사용 예시

### 1. 코드 설명 요청

```
> 이 파일의 주요 로직을 설명해줘
> Explain what this function does
```

Claude Code는 현재 디렉토리의 파일을 읽고 컨텍스트를 파악하여 답변합니다.

---

### 2. 버그 수정

```
> getUserById가 null을 반환하는 버그 찾아서 고쳐줘
> Fix the NullPointerException in UserService.java
```

파일을 직접 읽고, 수정 후 변경 내용을 보여줍니다.

---

### 3. 새 기능 추가

```
> 유저 목록을 페이징 처리하는 API 엔드포인트 추가해줘
> Add a REST endpoint GET /users with pagination
```

기존 코드 스타일을 파악하여 일관된 방식으로 코드를 추가합니다.

---

### 4. 테스트 작성

```
> OrderService의 단위 테스트 작성해줘
> Write unit tests for the payment module
```

---

### 5. 리팩토링

```
> 중복 코드 제거하고 공통 유틸 함수로 추출해줘
> Refactor this class to use the Strategy pattern
```

---

### 6. Git 작업

```
> 변경사항 요약해서 커밋 메시지 만들어줘
> Create a meaningful commit message for these changes
> git log 보고 최근 작업 요약해줘
```

---

### 7. 파일 검색 및 탐색

```
> 프로젝트에서 TODO 주석 모두 찾아줘
> 인증 관련 코드가 어디 있는지 찾아줘
> Find all usages of the deprecated API
```

---

### 8. 문서화

```
> 이 모듈의 README 작성해줘
> 공개 API에 JSDoc 주석 추가해줘
> Generate API documentation for this service
```

---

## 슬래시 커맨드

대화 중 슬래시(`/`)로 시작하는 명령어를 사용할 수 있습니다.

| 커맨드 | 설명 |
|--------|------|
| `/help` | 사용 가능한 커맨드 목록 |
| `/clear` | 대화 컨텍스트 초기화 |
| `/compact` | 긴 대화를 요약하여 컨텍스트 절약 |
| `/cost` | 현재 세션의 토큰 사용량 확인 |
| `/exit` | Claude Code 종료 |
| `/review-pr` | PR 리뷰 (스킬) |
| `/commit` | 커밋 생성 (스킬) |

---

## CLAUDE.md — 프로젝트 설정 파일

프로젝트 루트에 `CLAUDE.md`를 두면 Claude Code가 자동으로 읽어 컨텍스트를 설정합니다.

```markdown
# Project Guidelines

## Tech Stack
- Java 17, Spring Boot 3.x
- PostgreSQL, Redis
- JUnit 5, Mockito

## Conventions
- 변수명은 camelCase 사용
- 모든 public API에는 Javadoc 필수
- 커밋 메시지는 Conventional Commits 형식

## Commands
- 빌드: ./gradlew build
- 테스트: ./gradlew test
- 실행: ./gradlew bootRun
```

---

## 권한 모드 (Permission Mode)

Claude Code는 파일 수정 / 명령 실행 전에 사용자에게 승인을 요청합니다.

| 모드 | 설명 |
|------|------|
| 기본 | 모든 파일 수정/실행 전 확인 요청 |
| `--dangerously-skip-permissions` | 승인 없이 자동 실행 (주의!) |

```bash
# 자동 승인 모드로 실행 (CI/CD, 스크립트 환경)
claude --dangerously-skip-permissions
```

---

## MCP 서버 연동

MCP(Model Context Protocol) 서버를 연결하면 외부 도구와 통합할 수 있습니다.

```bash
# MCP 서버 추가
claude mcp add my-server -- npx my-mcp-server

# 등록된 MCP 서버 확인
claude mcp list
```

활용 예시:
- DB 직접 조회
- Slack / GitHub 연동
- 사내 API 호출

---

## 멀티턴 대화 팁

```
> 지금 auth 모듈 리팩토링할 거야. 시작 전에 현재 구조 파악해줘
> [Claude가 분석]
> 좋아. JwtFilter를 Spring Security 필터 체인으로 교체해줘
> [Claude가 수정]
> 테스트도 업데이트해줘
```

한 세션 안에서 컨텍스트가 유지되므로, 단계적으로 작업을 지시할 수 있습니다.

---

## 자주 쓰는 패턴 모음

```bash
# 프로젝트 전체 구조 파악
> 이 프로젝트의 아키텍처를 설명해줘. 주요 모듈과 흐름 위주로.

# 특정 파일 중심 작업
> src/service/PaymentService.java 읽고, 환불 로직에 버그 있는지 확인해줘

# 코드 리뷰
> 내가 방금 수정한 코드 리뷰해줘. 성능 이슈나 보안 취약점 중심으로.

# 의존성 분석
> 이 클래스를 삭제하면 어디에 영향을 주는지 찾아줘

# 환경 설정 도움
> Docker Compose로 로컬 개발 환경 세팅해줘. PostgreSQL + Redis 포함.
```

---

## 참고 링크

- [공식 문서](https://docs.anthropic.com/en/docs/claude-code)
- [GitHub](https://github.com/anthropics/claude-code)
- [이슈 리포트](https://github.com/anthropics/claude-code/issues)
