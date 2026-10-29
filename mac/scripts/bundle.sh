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
codesign --force --sign - "$APP"

echo "$(pwd)/$APP"
