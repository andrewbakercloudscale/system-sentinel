#!/bin/bash
# Installs (or updates to) the latest System Sentinel release in /Applications.
set -euo pipefail
REPO="andrewbakercloudscale/system-sentinel"
APP="${SYSTEM_SENTINEL_APP:-/Applications/System Sentinel.app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== Downloading the latest release"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh release download --repo "$REPO" --pattern '*Sentinel-*.zip' --dir "$TMP"
else
  URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4 || true)"
  if [ -z "$URL" ]; then
    echo "Could not reach the release. If the repository is private, install GitHub CLI"
    echo "(brew install gh), run: gh auth login, then run this script again."
    exit 1
  fi
  curl -fL --progress-bar -o "$TMP/System-Sentinel.zip" "$URL"
fi
ZIP="$(ls "$TMP"/*.zip | head -1)"

echo "== Installing to $APP"
pkill -x SystemSentinel 2>/dev/null || true
pkill -x CPUSentinel 2>/dev/null || true        # its name before 0.7.0
rm -rf "/Applications/CPU Sentinel.app"
ditto -x -k "$ZIP" "$TMP/unzipped"
rm -rf "$APP"
ditto "$(ls -d "$TMP"/unzipped/*.app | head -1)" "$APP"
# Not notarised by Apple: clear only the download quarantine flag.
xattr -dr com.apple.quarantine "$APP"

if [ -z "${SYSTEM_SENTINEL_NO_OPEN:-}" ]; then
  echo "== Launching"
  open "$APP"
fi
echo "Done: $(defaults read "$APP/Contents/Info" CFBundleShortVersionString). Look for the red chip in the menu bar."
