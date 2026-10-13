#!/bin/bash
# 릴리스 한 번에: DMG 빌드 → GitHub 릴리스 생성 → Snackbar 사이트에 갱신 신호.
#
#   scripts/release.sh v1.2.3 --notes-file notes.md
#   scripts/release.sh v1.2.3 --notes "한 줄 변경내역"
#
# 태그 뒤 인자는 그대로 `gh release create`에 넘어간다. 릴리스 노트의 첫 문단이
# Snackbar "최근 업데이트"에 요약으로 실리니, 무엇이 바뀌었는지부터 쓴다.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release.sh <tag> [gh release create 옵션...]}"
shift

# 릴리스 태그는 원격 main에 찍힌다. 로컬과 다르면 DMG와 태그가 어긋난다.
git fetch -q origin
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "커밋 안 된 변경이 있거나 origin/main과 다릅니다. 커밋·push 후 다시 실행하세요." >&2
  exit 1
fi

./scripts/build_dmg.sh

gh release create "$TAG" "Soundwich.dmg" --title "Soundwich $TAG 🥪" "$@"

# Snackbar(zzanggi-haki/snackbar)가 이 신호를 받아 사이트를 다시 빌드한다.
gh api -X POST repos/zzanggi-haki/snackbar/dispatches -f event_type=app-released >/dev/null \
  && echo "==> Snackbar 갱신 신호 보냄" \
  || echo "!! Snackbar 신호 실패 — snackbar 레포 Actions에서 수동 실행하세요" >&2
