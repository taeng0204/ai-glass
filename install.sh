#!/bin/bash
# AI Glass 원클릭 설치 스크립트
#   curl -fsSL https://raw.githubusercontent.com/taeng0204/ai-glass/main/install.sh | bash
set -euo pipefail

REPO="taeng0204/ai-glass"
APP_NAME="AIGlass.app"
DEST="/Applications/${APP_NAME}"

echo "🔮 AI Glass 설치를 시작합니다..."

# macOS 26+ 확인
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "${MAJOR}" -lt 26 ]; then
  echo "❌ macOS 26 (Tahoe) 이상이 필요합니다. 현재: $(sw_vers -productVersion)"
  exit 1
fi

# 최신 릴리스 zip URL 조회
echo "→ 최신 릴리스 확인 중..."
ZIP_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*AIGlass[^"]*\.zip"' \
  | head -1 | cut -d'"' -f4)
if [ -z "${ZIP_URL}" ]; then
  echo "❌ 릴리스에서 AIGlass zip을 찾지 못했습니다: https://github.com/${REPO}/releases"
  exit 1
fi

# 다운로드 & 압축 해제
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
echo "→ 다운로드: ${ZIP_URL}"
curl -fsSL -o "${TMP}/AIGlass.zip" "${ZIP_URL}"
ditto -xk "${TMP}/AIGlass.zip" "${TMP}/extracted"

APP_SRC=$(find "${TMP}/extracted" -maxdepth 2 -name "${APP_NAME}" | head -1)
if [ -z "${APP_SRC}" ]; then
  echo "❌ zip 안에서 ${APP_NAME}을 찾지 못했습니다."
  exit 1
fi

# 기존 설치 정리 (실행 중이면 종료)
pkill -f "AIGlass.app/Contents/MacOS" 2>/dev/null || true
rm -rf "${DEST}"
ditto "${APP_SRC}" "${DEST}"

# Gatekeeper 격리 해제 (ad-hoc 서명 빌드 — 코드는 GitHub에서 열람 가능)
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "→ 실행..."
open "${DEST}"

echo ""
echo "✅ 설치 완료! 화면 우상단의 liquid glass 알약과 메뉴바 ✦ 아이콘을 확인하세요."
echo ""
echo "  처음 실행 팁:"
echo "  · 온보딩에서 웨이브 스타일/메뉴바 모드를 고를 수 있어요"
echo "  · Claude 한도 조회용 Keychain 다이얼로그가 뜨면 \"항상 허용\"을 눌러주세요"
echo "  · 단축키: ⌘⇧U 대시보드 · ⌘⇧E 알약 확장"
