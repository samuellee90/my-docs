#!/bin/bash
# 문서 추가 후 GitHub에 자동 push하는 스크립트
# 사용법: ./push.sh "커밋 메시지"

MSG=${1:-"docs: update"}

cd "$(dirname "$0")"

# _sidebar.md 변경 시 sidebar.md에 자동 동기화
if [ docs/_sidebar.md -nt docs/sidebar.md ] 2>/dev/null; then
  cp docs/_sidebar.md docs/sidebar.md
fi

git add .
git commit -m "$MSG"
git push origin main

echo "✓ 완료! GitHub Pages에서 확인하세요."
