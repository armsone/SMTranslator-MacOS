#!/bin/bash
# Resources/AppIcon-source.png(생성된 원본 아이콘)로부터 표준 .iconset을 sips로 만들고
# iconutil로 Resources/AppIcon.icns를 생성한다. 알파 채널은 PNG 그대로 유지된다.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon-source.png"
OUTPUT="$ROOT_DIR/Resources/AppIcon.icns"
WORK_DIR="$(mktemp -d /private/tmp/screentranslator-icon.XXXXXX)"
ICONSET="$WORK_DIR/AppIcon.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "==> 아이콘 생성: $OUTPUT"
