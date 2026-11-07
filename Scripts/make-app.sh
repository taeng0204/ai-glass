#!/usr/bin/env bash
# AI Glass .app 번들 생성 스크립트.
# release 빌드 → Info.plist 생성 → 바이너리 복사 → ad-hoc 코드사인.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AIGlass"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "==> release 빌드 중..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
    echo "빌드 산출물을 찾지 못했습니다: ${BIN_PATH}" >&2
    exit 1
fi

echo "==> 번들 구조 생성: ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

echo "==> Info.plist 생성"
cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.taeng.aiglass</string>
    <key>CFBundleName</key>
    <string>AI Glass</string>
    <key>CFBundleExecutable</key>
    <string>AIGlass</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.18.2</string>
    <key>CFBundleVersion</key>
    <string>0.18.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST

echo "==> 바이너리 복사"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> 앱 아이콘 복사"
if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
else
    echo "경고: Assets/AppIcon.icns 없음 — 아이콘 없이 진행" >&2
fi

# 서명 신원: 로컬 자체 인증서 "AIGlass Local"이 키체인에 있으면 그걸로 서명한다.
# ad-hoc 서명은 빌드마다 앱 지문이 바뀌어 Keychain(Claude 인증정보) 접근 허용이 매번 초기화되지만,
# 고정 인증서로 서명하면 designated requirement가 유지되어 "항상 허용"이 재빌드 후에도 남는다.
# (인증서가 없으면 ad-hoc으로 대체. 만들기: scripts/setup-signing.sh)
SIGN_ID="${AIGLASS_SIGN_ID:-AIGlass Local}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"${SIGN_ID}\""; then
    echo "==> 코드사인 (${SIGN_ID})"
    codesign --force --deep -s "${SIGN_ID}" "${APP_DIR}"
else
    echo "==> ad-hoc 코드사인 (인증서 '${SIGN_ID}' 없음 — Keychain 허용이 재빌드마다 초기화됨)"
    codesign --force --deep -s - "${APP_DIR}"
fi

echo ""
echo "완료: ${APP_DIR}"
echo ""
echo "실행:        open ${APP_DIR}"
echo "설치(선택):  cp -r ${APP_DIR} /Applications/"
echo "종료:        pkill -f ${APP_NAME}.app/Contents/MacOS"
echo ""
echo "주의: 자동 시작/알림센터는 .app 번들에서만 동작합니다 (swift run에서는 no-op)."
