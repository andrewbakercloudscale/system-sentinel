#!/usr/bin/env bash
# Builds a zip of System Sentinel.app for a GitHub release, in dist/.
#
#   bash scripts/release.sh
#
# With a Developer ID it is signed with the hardened runtime and notarised, so it opens on
# any Mac without warnings:
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=system-sentinel bash scripts/release.sh
#
# NOTARY_PROFILE is a keychain profile made once with
#   xcrun notarytool store-credentials system-sentinel --apple-id you@example.com --team-id TEAMID
#
# Without them the app is ad-hoc signed: users must clear the quarantine flag, `xattr -dr com.apple.quarantine`, on it (see the README).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP="build/System Sentinel.app"
ZIP="dist/System-Sentinel-$VERSION.zip"

echo "== tests"
swift test >/dev/null 2>&1 || { echo "tests failed, not releasing"; exit 1; }

echo "== build $VERSION"
# Universal: Apple chips and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SystemSentinel"
lipo "$BIN" -verify_arch arm64 x86_64 || { echo "not universal, not releasing"; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp "$BIN" "$APP/Contents/MacOS/SystemSentinel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "== sign: $DEVELOPER_ID"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "== notarise"
        ditto -c -k --keepParent "$APP" "dist/notarise.zip"
        xcrun notarytool submit "dist/notarise.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        rm -f "dist/notarise.zip"
        xcrun stapler staple "$APP"
        spctl --assess --type execute --verbose "$APP"
    else
        echo "!! NOTARY_PROFILE not set: signed but not notarised, Gatekeeper will still warn"
    fi
else
    source "$(dirname "$0")/sign-id.sh"
    echo "== sign: $SENTINEL_SIGN_ID (no DEVELOPER_ID: users need xattr -dr com.apple.quarantine)"
    codesign --force --sign "$SENTINEL_SIGN_ID" "$APP"
    codesign --verify "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "== $ZIP ($(du -h "$ZIP" | cut -f1))"
