#!/usr/bin/env bash
# Build mac/build/Kervan.app (release, ad-hoc signed). Usage: mac/scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Kervan
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/Kervan.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Kervan" "$APP/Contents/MacOS/Kervan"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: every size macOS asks for, from the one 1024 px master (see scripts/icon-from-render.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "$(pwd)/$APP"
