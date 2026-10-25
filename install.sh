#!/bin/bash
# Installs (or updates to) the latest System Sentinel release in /Applications, or in
# ~/Applications on an account that cannot write to /Applications.
# Needs nothing beyond macOS itself: curl, ditto, xattr and file are built in.
set -euo pipefail
REPO="andrewbakercloudscale/system-sentinel"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

stop() { echo; echo "!! $1"; echo; exit 1; }

echo "== Checking this Mac"
OS="$(sw_vers -productVersion)"
if [ "${OS%%.*}" -lt 14 ]; then
  stop "This Mac runs macOS $OS. System Sentinel needs macOS 14 (Sonoma) or later.
   Update it in System Settings, General, Software Update, then run this again."
fi
if [ -n "${SYSTEM_SENTINEL_APP:-}" ]; then
  APP="$SYSTEM_SENTINEL_APP"
elif [ -w /Applications ]; then
  APP="/Applications/System Sentinel.app"
else
  # A standard (not administrator) account cannot write to /Applications.
  mkdir -p "$HOME/Applications"
  APP="$HOME/Applications/System Sentinel.app"
fi
echo "   macOS $OS, $(uname -m), installing to $APP"

echo "== Downloading the latest release"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh release download --repo "$REPO" --pattern '*Sentinel-*.zip' --dir "$TMP"
else
  URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4 || true)"
  if [ -z "$URL" ]; then
    stop "Could not reach GitHub. Check the internet connection and run this again."
  fi
  curl -fL --progress-bar -o "$TMP/System-Sentinel.zip" "$URL"
fi
ZIP="$(ls "$TMP"/*.zip | head -1)"
ditto -x -k "$ZIP" "$TMP/unzipped"
NEW="$(ls -d "$TMP"/unzipped/*.app | head -1)"

# Releases before 0.8.35 were built for Apple chips (M1 and later) only.
ARCH="$(uname -m)"
if ! file "$NEW/Contents/MacOS/SystemSentinel" | grep -q "$ARCH"; then
  stop "This release does not run on this Mac's chip ($ARCH). Nothing was installed."
fi

echo "== Installing"
pkill -x SystemSentinel 2>/dev/null || true
pkill -x CPUSentinel 2>/dev/null || true        # its name before 0.7.0
rm -rf "/Applications/CPU Sentinel.app" 2>/dev/null || true
rm -rf "$APP"
ditto "$NEW" "$APP"
# Not notarised by Apple: clear only the download quarantine flag.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [ -z "${SYSTEM_SENTINEL_NO_OPEN:-}" ]; then
  echo "== Launching"
  open "$APP"
fi
echo "Done: $(defaults read "$APP/Contents/Info" CFBundleShortVersionString). Look for the red chip in the menu bar."
