#!/bin/bash
# Sparkle 2.10.0 공식 배포본을 고정 URL + SHA256으로 검증한 뒤 Vendor/Sparkle에 풀어 둔다.
# 사용법: scripts/bootstrap-sparkle.sh
#   SPARKLE_TARBALL=/경로/Sparkle-2.10.0.tar.xz 를 지정하면 다운로드 대신 그 파일을 검증해 사용한다.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.10.0"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
VENDOR_DIR="$ROOT_DIR/Vendor/Sparkle"
DOWNLOAD_DIR="$ROOT_DIR/build-deps/downloads"
TARBALL="${SPARKLE_TARBALL:-$DOWNLOAD_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz}"

if [ ! -f "$TARBALL" ]; then
  mkdir -p "$DOWNLOAD_DIR"
  echo "==> Sparkle ${SPARKLE_VERSION} 다운로드"
  curl -fL --proto '=https' --tlsv1.2 -o "$TARBALL.partial" "$SPARKLE_URL"
  mv "$TARBALL.partial" "$TARBALL"
fi

ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
  echo "오류: Sparkle 아카이브 SHA256 불일치 (기대 $SPARKLE_SHA256, 실제 $ACTUAL)" >&2
  exit 1
fi
echo "==> SHA256 확인: $ACTUAL"

rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
tar -xJf "$TARBALL" -C "$VENDOR_DIR"
echo "$SPARKLE_VERSION $SPARKLE_SHA256" > "$VENDOR_DIR/VERSION"
echo "==> Sparkle 준비 완료: $VENDOR_DIR"
