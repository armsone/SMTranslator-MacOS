#!/bin/bash
# ScreenTranslator.app 빌드 스크립트
# 사용법: ./build.sh
#   SIGN_IDENTITY  : 서명 인증서 SHA1 (기본: 기존 Developer ID Application, 팀 T7B4EPLHPK)
#   SIGN_TIMESTAMP : 1이면 보안 타임스탬프 포함(배포/공증용, 네트워크 필요)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="ScreenTranslator"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_NAME="ScreenTranslator"
BUNDLE_ID="com.local.screentranslator"
SPARKLE_DIR="$ROOT_DIR/Vendor/Sparkle"
SIGN_IDENTITY="${SIGN_IDENTITY:-56C14CF3A623A4C64AF71A3D63C248FEAB4D8DB8}"

# shellcheck source=update-config.env
source "$ROOT_DIR/update-config.env"

if [ ! -d "$SPARKLE_DIR/Sparkle.framework" ]; then
  echo "==> Sparkle 의존성 준비"
  "$ROOT_DIR/scripts/bootstrap-sparkle.sh"
fi

if [ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ] || [ "$ROOT_DIR/Resources/AppIcon-source.png" -nt "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  echo "==> 앱 아이콘 생성"
  "$ROOT_DIR/scripts/make-icon.sh"
fi

echo "==> 빌드 디렉터리 정리"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
if [ "$(uname -m)" = "arm64" ]; then
  SWIFT_TARGET="arm64-apple-macos15.0"
else
  SWIFT_TARGET="x86_64-apple-macos15.0"
fi

echo "==> Swift 소스 컴파일 (target: $SWIFT_TARGET)"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -F "$SPARKLE_DIR" \
  -framework Sparkle \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework Translation \
  -framework ServiceManagement \
  -framework Carbon \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" \
  "$ROOT_DIR"/Sources/*.swift

echo "==> 리소스/Info.plist/프레임워크 복사"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$PLIST"
PUBLIC_KEY_FILE="$ROOT_DIR/Resources/UpdatePublicKey.txt"
if [ -f "$PUBLIC_KEY_FILE" ]; then
  PUBLIC_KEY="$(tr -d '[:space:]' < "$PUBLIC_KEY_FILE")"
  if [[ ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "오류: Resources/UpdatePublicKey.txt가 EdDSA 공개키(base64 44자) 형식이 아닙니다." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$PLIST"
  echo "==> SUPublicEDKey 포함 (공개키)"
else
  echo "경고: Resources/UpdatePublicKey.txt 없음 — 자동 업데이트가 비활성 상태로 빌드됩니다." >&2
fi
plutil -lint "$PLIST" >/dev/null

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [ "${SIGN_TIMESTAMP:-0}" = "1" ]; then
  SIGN_ARGS+=(--timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi

echo "==> Sparkle 내부 구성요소 서명 (안쪽부터)"
FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FW"

echo "==> 앱 서명 (identity: $SIGN_IDENTITY, identifier: $BUNDLE_ID)"
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "==> 빌드 완료: $APP_BUNDLE"
