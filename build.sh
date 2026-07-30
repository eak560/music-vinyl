#!/bin/bash
# Builds Music Vinyl and assembles a runnable .app bundle in ./build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP="build/Music Vinyl.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/MusicVinyl"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MusicVinyl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature keeps macOS (and the Automation permission prompt) happy.
echo "==> Signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "==> Built: $APP"
