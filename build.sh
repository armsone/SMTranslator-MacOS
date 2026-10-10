#!/bin/bash
# Barobogi.app 빌드 스크립트
# 사용법: ./build.sh
#   SIGN_IDENTITY  : 서명 인증서 SHA1 (기본: 기존 Developer ID Application, 팀 T7B4EPLHPK)
#   SIGN_TIMESTAMP : 1이면 보안 타임스탬프 포함(배포/공증용, 네트워크 필요)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Barobogi"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_NAME="Barobogi"
BUNDLE_ID="com.local.screentranslator"
SPARKLE_DIR="$ROOT_DIR/Vendor/Sparkle"
# 앱 본체 권한: Mail 선택 메시지 읽기용 Apple Events만(hardened runtime 유지, 라이브러리 검증 완화 없음)
ENTITLEMENTS="$ROOT_DIR/Resources/SMTranslator.entitlements"
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
  -framework WebKit \
  -framework NaturalLanguage \
  -framework UniformTypeIdentifiers \
  -framework ApplicationServices \
  -framework SafariServices \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" \
  "$ROOT_DIR"/Sources/*.swift

# 브라우저 번역: Chrome·Whale 네이티브 메시징 도우미, 압축 해제용 확장, Safari 웹 확장(.appex)
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ROOT_DIR/Info.plist")"
BROWSER_DIR="$ROOT_DIR/BrowserExtension"
HELPER_ID="com.local.screentranslator.browserhost"
SAFARI_APPEX="$APP_BUNDLE/Contents/PlugIns/SMTSafariExtension.appex"
SAFARI_ID="com.local.screentranslator.safari-extension"
SAFARI_ENTITLEMENTS="$ROOT_DIR/SafariExtension/SafariExtension.entitlements"

echo "==> 브라우저 도우미 컴파일 (SMTBrowserHost)"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -module-name SMTBrowserHost \
  -framework AppKit \
  -framework Security \
  -o "$APP_BUNDLE/Contents/Helpers/SMTBrowserHost" \
  "$BROWSER_DIR/NativeHost/main.swift" \
  "$ROOT_DIR/Sources/BrowserProtocol.swift"

echo "==> 브라우저 확장 파일 준비 (버전 $APP_VERSION)"
ICON_DIR="$BUILD_DIR/browser-icons"
rm -rf "$ICON_DIR"
mkdir -p "$ICON_DIR"
# 앱 아이콘 원본은 Finder/Dock용 여백(약 9%)이 포함돼 있어 그대로 축소하면 브라우저 툴바에서 다른 확장
# 아이콘보다 작아 보인다. 여백을 크롭해 같은 그림을 꽉 채워 생성한다(디자인 변경 없음, 비율만 조정).
BROWSER_ICON_SOURCE="$ICON_DIR/_source-cropped.png"
sips -s format png -c 1060 1060 "$ROOT_DIR/Resources/AppIcon-source.png" --out "$BROWSER_ICON_SOURCE" >/dev/null
for size in 16 32 48 128; do
  sips -z "$size" "$size" "$BROWSER_ICON_SOURCE" --out "$ICON_DIR/icon$size.png" >/dev/null
done
rm -f "$BROWSER_ICON_SOURCE"
# stage_extension <대상 폴더> <manifest 원본>
stage_extension() {
  local dest="$1" manifest="$2"
  mkdir -p "$dest/icons" "$dest/fonts"
  cp "$BROWSER_DIR/shared/background.js" "$BROWSER_DIR/shared/content.js" \
     "$BROWSER_DIR/shared/popup.html" "$BROWSER_DIR/shared/popup.js" "$BROWSER_DIR/shared/popup.css" "$dest/"
  cp "$ICON_DIR"/icon*.png "$dest/icons/"
  # 고딕/명조/손글씨 글꼴(패키지 번들, 온라인 Google Fonts 의존 안 함). 라이선스(OFL)도 함께 접근 가능하게 둔다.
  cp "$ROOT_DIR/Resources/Fonts"/*.ttf "$dest/fonts/"
  cp "$ROOT_DIR/Resources/Fonts"/*-OFL.txt "$ROOT_DIR/Resources/Fonts"/*-LICENSE.txt "$dest/fonts/"
  sed "s/__SMT_VERSION__/$APP_VERSION/" "$manifest" > "$dest/manifest.json"
  plutil -convert json -o /dev/null "$dest/manifest.json"
}
stage_extension "$APP_BUNDLE/Contents/Resources/BrowserExtension/Chromium" "$BROWSER_DIR/chromium/manifest.json"

echo "==> Safari 웹 확장(.appex) 컴파일"
mkdir -p "$SAFARI_APPEX/Contents/MacOS" "$SAFARI_APPEX/Contents/Resources"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -parse-as-library \
  -application-extension \
  -module-name SMTSafariExtension \
  -framework Foundation \
  -framework AppKit \
  -framework SafariServices \
  -framework Translation \
  -framework Vision \
  -framework NaturalLanguage \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$SAFARI_APPEX/Contents/MacOS/SMTSafariExtension" \
  "$ROOT_DIR/SafariExtension/SafariWebExtensionHandler.swift" \
  "$ROOT_DIR/Sources/BrowserEngineCore.swift" \
  "$ROOT_DIR/Sources/BrowserProtocol.swift" \
  "$ROOT_DIR/Sources/Models.swift" \
  "$ROOT_DIR/Sources/BundledFonts.swift" \
  "$ROOT_DIR/Sources/ImageTextRecognizer.swift" \
  "$ROOT_DIR/Sources/DocumentTextRecognizer.swift" \
  "$ROOT_DIR/Sources/AppleTranslationRefiner.swift"
cp "$ROOT_DIR/SafariExtension/Info.plist" "$SAFARI_APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$SAFARI_APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$SAFARI_APPEX/Contents/Info.plist"
plutil -lint "$SAFARI_APPEX/Contents/Info.plist" >/dev/null
stage_extension "$SAFARI_APPEX/Contents/Resources" "$BROWSER_DIR/safari/manifest.json"

echo "==> 리소스/Info.plist/프레임워크 복사"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# 외부 AI(AIBI 0.5.3) 공통 런타임과 제공사 레지스트리 — 메일 번역기 원본과 같은 파일
cp "$ROOT_DIR/Resources/aibi-browser-runtime.js" "$ROOT_DIR/Resources/aibi-providers.json" "$APP_BUNDLE/Contents/Resources/"
# 화면 번역문 글꼴(고딕/명조/손글씨, 패키지 번들). 앱 실행 중 프로세스 범위로만 등록하며 시스템에 설치하지 않는다.
mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
cp "$ROOT_DIR/Resources/Fonts"/*.ttf "$ROOT_DIR/Resources/Fonts"/*-OFL.txt "$ROOT_DIR/Resources/Fonts"/*-LICENSE.txt "$APP_BUNDLE/Contents/Resources/Fonts/"
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

echo "==> 브라우저 도우미·Safari 확장 서명"
# 도우미: 권한 없음(hardened runtime). 앱 엔진은 이 식별자 + 같은 팀 서명만 연결을 받는다.
codesign "${SIGN_ARGS[@]}" --identifier "$HELPER_ID" "$APP_BUNDLE/Contents/Helpers/SMTBrowserHost"
# Safari 확장: 앱 샌드박스만(앱 그룹·임시 예외 없음)
plutil -lint "$SAFARI_ENTITLEMENTS" >/dev/null
codesign "${SIGN_ARGS[@]}" --entitlements "$SAFARI_ENTITLEMENTS" --identifier "$SAFARI_ID" "$SAFARI_APPEX"

echo "==> 앱 서명 (identity: $SIGN_IDENTITY, identifier: $BUNDLE_ID, entitlements: Apple Events)"
plutil -lint "$ENTITLEMENTS" >/dev/null
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "==> 빌드 완료: $APP_BUNDLE"
