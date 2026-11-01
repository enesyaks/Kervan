#!/usr/bin/env bash
# Installs or updates Kervan for Mac from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/enesyaks/Kervan/main/install.sh | bash
#
# It downloads the app, checks it against the checksum published with it, puts it in Applications and opens it.
# Downloaded this way the app isn't marked as coming from the internet, so macOS opens it straight away, without
# the "Open Anyway" detour a browser download needs. Later versions install from inside the app.
set -euo pipefail

REPO="enesyaks/Kervan"
fail() { echo "Kervan: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "this installs the Mac app; it needs macOS."
version_mac="$(sw_vers -productVersion)"
(( ${version_mac%%.*} >= 14 )) || fail "Kervan needs macOS 14 or later; this Mac has $version_mac."

echo "Finding the latest Kervan…"
release="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" || fail "couldn't reach GitHub."
asset() { printf '%s' "$release" | grep -o "\"browser_download_url\": *\"[^\"]*$1\"" | head -1 | sed -E 's/.*"(https[^"]*)"$/\1/'; }
zip_url="$(asset '-macOS\.zip')"
sum_url="$(asset '-macOS\.zip\.sha256')"
[[ -n "$zip_url" && -n "$sum_url" ]] || fail "the latest release has no Mac app; see https://github.com/$REPO/releases"
version="$(basename "$zip_url" | sed -E 's/^Kervan-(.*)-macOS\.zip$/\1/')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "Downloading Kervan $version…"
curl -fsSL -o "$work/Kervan.zip" "$zip_url"
expected="$(curl -fsSL "$sum_url" | awk '{print $1}')"
actual="$(shasum -a 256 "$work/Kervan.zip" | awk '{print $1}')"
[[ -n "$expected" && "$expected" == "$actual" ]] || fail "the download doesn't match its checksum; nothing was installed."
ditto -x -k "$work/Kervan.zip" "$work/unpacked"
app="$work/unpacked/Kervan.app"
[[ -d "$app" ]] || fail "the download doesn't contain Kervan.app."
if ! lipo -archs "$app/Contents/MacOS/Kervan" | grep -qw "$(uname -m)"; then
  fail "Kervan $version doesn't run on this Mac's processor ($(uname -m)) yet."
fi

# Applications when this account may write there (admins can), else the user's own Applications folder.
dest="/Applications"
[[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

# A running copy closes first, so the new one replaces it cleanly; the old one comes back if anything fails.
osascript -e 'tell application id "com.enes.kervan" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -qf "Kervan.app/Contents/MacOS/Kervan" || break; sleep 0.5; done
if [[ -d "$dest/Kervan.app" ]]; then mv "$dest/Kervan.app" "$work/previous.app"; fi
if ! ditto "$app" "$dest/Kervan.app"; then
  [[ -d "$work/previous.app" ]] && mv "$work/previous.app" "$dest/Kervan.app"
  fail "couldn't copy the app into $dest."
fi
xattr -dr com.apple.quarantine "$dest/Kervan.app" 2>/dev/null || true

echo "Kervan $version is in $dest. Opening it…"
open "$dest/Kervan.app"
