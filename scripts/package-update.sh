#!/bin/bash
# 업데이트 배포 산출물(DMG + 서명된 appcast.xml)을 만든다. 게시(업로드)는 하지 않는다.
# 사용법: scripts/package-update.sh
#   SPARKLE_KEYCHAIN_ACCOUNT : 로그인 키체인의 EdDSA 서명 키 계정명
#                              (기본: Resources/UpdateSigningAccount.txt 내용)
#   NOTARY_PROFILE           : 지정 시 notarytool 키체인 프로필로 공증 후 staple
# 개인키는 sign_update/generate_appcast가 키체인에서 직접 읽으며, 이 스크립트는 키를
# 내보내거나 출력하지 않는다.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../update-config.env
source "$ROOT_DIR/update-config.env"

ACCOUNT_FILE="$ROOT_DIR/Resources/UpdateSigningAccount.txt"
if [ -z "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ] && [ -f "$ACCOUNT_FILE" ]; then
  SPARKLE_KEYCHAIN_ACCOUNT="$(tr -d '[:space:]' < "$ACCOUNT_FILE")"
fi
if [ -z "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]; then
  echo "오류: SPARKLE_KEYCHAIN_ACCOUNT(서명 키 키체인 계정)가 지정되지 않았습니다." >&2
  exit 1
fi
if [ ! -f "$ROOT_DIR/Resources/UpdatePublicKey.txt" ]; then
  echo "오류: Resources/UpdatePublicKey.txt가 없어 업데이트 검증 키 없이 배포할 수 없습니다." >&2
  exit 1
fi

SIGN_TIMESTAMP=1 "$ROOT_DIR/build.sh"

APP="$ROOT_DIR/build/SMTranslator.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-56C14CF3A623A4C64AF71A3D63C248FEAB4D8DB8}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
RELEASE_DIR="$ROOT_DIR/build/release/v$VERSION"
DMG="$RELEASE_DIR/SMTranslator-$VERSION.dmg"
STAGING="$(mktemp -d /private/tmp/screentranslator-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "==> DMG 생성"
ditto "$APP" "$STAGING/SMTranslator.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SMTranslator $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> 공증 제출 (프로필: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "참고: NOTARY_PROFILE 미지정 — 공증 없이 생성했습니다. 게시 전 공증이 필요합니다." >&2
fi

echo "==> appcast 생성 및 EdDSA 서명 (키체인 계정: $SPARKLE_KEYCHAIN_ACCOUNT)"
"$ROOT_DIR/Vendor/Sparkle/bin/generate_appcast" \
  --account "$SPARKLE_KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_BASE/v$VERSION/" \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR"

echo "==> 산출물 (게시하지 않음):"
ls -l "$RELEASE_DIR"
echo "피드 URL: $SPARKLE_FEED_URL"
echo "게시 시 DMG와 appcast.xml을 릴리스 v$VERSION 자산으로 올리고 해당 릴리스를 latest로 지정해야 합니다."
