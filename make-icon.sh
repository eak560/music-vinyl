#!/bin/bash
# Renders the app icon from the same SwiftUI code that draws the record and
# packs it into Resources/AppIcon.icns. Run this only when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MusicVinyl"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BIN" --render-icon "$WORK/icon.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "==> Wrote Resources/AppIcon.icns"
