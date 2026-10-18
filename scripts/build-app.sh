#!/usr/bin/env bash
# Builds System Sentinel.app and installs it to ~/Applications.
#
#   bash scripts/build-app.sh            # test, build, bundle, install, launch
#   bash scripts/build-app.sh --no-open  # same, without launching
#
# Ad-hoc signed: it runs on this Mac only. Sharing it needs a Developer ID and notarisation.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== tests"
swift test 2>&1 | tail -3
swift test >/dev/null 2>&1 || { echo "tests failed, not building"; exit 1; }

echo "== build"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/SystemSentinel"

APP="build/System Sentinel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SystemSentinel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
source "$(dirname "$0")/sign-id.sh"
echo "== sign: $SENTINEL_SIGN_ID"
codesign --force --sign "$SENTINEL_SIGN_ID" "$APP"
codesign --verify "$APP"

DEST="$HOME/Applications/System Sentinel.app"
mkdir -p "$HOME/Applications"
pkill -x SystemSentinel 2>/dev/null || true
# Before 0.7.0 the app was CPU Sentinel; leave only one copy.
pkill -x CPUSentinel 2>/dev/null || true
rm -rf "$HOME/Applications/CPU Sentinel.app"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "== installed: $DEST"

if [[ "${1:-}" != "--no-open" ]]; then
    open "$DEST"
    echo "== launched; look for the red chip icon in the menu bar"
fi
