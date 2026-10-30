#!/usr/bin/env bash
# Builds the files a GitHub release needs: mac/build/Kervan-<version>-macOS.zip and its .sha256, which the
# app's updater checks before installing. Usage: mac/scripts/release.sh, then:
#   gh release create v<version> build/Kervan-<version>-macOS.zip build/Kervan-<version>-macOS.zip.sha256
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if ! grep -q "\"$VERSION\"" ../server/src/version.ts; then
  echo "server/src/version.ts doesn't say $VERSION; release them together." >&2
  exit 1
fi

scripts/bundle.sh >/dev/null
ZIP="Kervan-$VERSION-macOS.zip"
cd build
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent Kervan.app "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "$(pwd)/$ZIP"
cat "$ZIP.sha256"
