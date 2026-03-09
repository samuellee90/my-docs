# Git 명령어 모음

## 자주 쓰는 명령어

| 명령어 | 설명 |
|--------|------|
| `git status` | 변경사항 확인 |
| `git add .` | 전체 스테이징 |
| `git commit -m "메시지"` | 커밋 |
| `git push origin main` | 푸시 |
| `git pull` | 풀 |
| `git log --oneline` | 커밋 히스토리 (간략) |

## 브랜치

```bash
git branch feature/new    # 브랜치 생성
git checkout feature/new  # 브랜치 이동
git checkout -b feature/new  # 생성 + 이동 동시에

git merge feature/new     # 병합
git branch -d feature/new # 브랜치 삭제
```

## 되돌리기

```bash
# 마지막 커밋 수정 (push 전에만)
git commit --amend

# 스테이징 취소
git restore --staged <file>

# 변경사항 버리기
git restore <file>

# 특정 커밋으로 되돌리기 (히스토리 유지)
git revert <commit-hash>
```

## 유용한 설정

```bash
# 단축키 설정
git config --global alias.st status
git config --global alias.lg "log --oneline --graph --all"
```
