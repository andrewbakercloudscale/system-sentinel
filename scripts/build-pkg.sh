#!/usr/bin/env bash
# Wraps build/System Sentinel.app in an installer package for MDM (Jamf, Intune, Kandji...).
#
#   bash scripts/build-pkg.sh            # after scripts/release.sh, which runs it itself
#
# Installs to /Applications/System Sentinel.app, owned by root, always there: the package is
# not relocatable, so it never "upgrades" a stray copy in ~/Applications or Downloads instead.
# Before installing it quits a running copy; afterwards it starts the new one for the person
# logged in, so an MDM update does not leave a hole in the recording.
#
# Signed with the publisher team's Developer ID Installer certificate and notarised once
# SENTINEL_PUBLISHER_TEAM is set in sign-id.sh. Until then the package is unsigned: Jamf and
# Kandji deploy it as it is; Intune needs the "unmanaged macOS PKG" app type, which accepts it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sign-id.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP="build/System Sentinel.app"
PKG="dist/System-Sentinel-$VERSION.pkg"
[[ -d "$APP" ]] || { echo "no $APP: run scripts/release.sh first" >&2; exit 1; }
[[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] \
    || { echo "$APP is not version $VERSION: run scripts/release.sh first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sentinel-pkg-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/scripts" dist
ditto --norsrc --noextattr --noqtn "$APP" "$WORK/root/Applications/System Sentinel.app"
# No extended attributes: they would ride along as ._ files in the payload.
xattr -cr "$WORK/root/Applications/System Sentinel.app"
codesign --verify --strict "$WORK/root/Applications/System Sentinel.app"
# The same mode as the real /Applications, so the payload never asks to tighten it.
chmod 775 "$WORK/root/Applications"

pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
# Replace, not Set: pkgbuild leaves BundleIsRelocatable out, and out means relocatable.
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"
# An older copy from MDM is replaced even if someone installed a newer one by hand.
plutil -replace 0.BundleIsVersionChecked -bool NO "$WORK/components.plist"

cat > "$WORK/scripts/preinstall" <<'EOF'
#!/bin/bash
# Quit a running copy politely, so it saves its history, then make sure it is gone.
pkill -TERM -x SystemSentinel 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x SystemSentinel >/dev/null || break; sleep 0.5; done
pkill -KILL -x SystemSentinel 2>/dev/null || true
pkill -x CPUSentinel 2>/dev/null || true          # its name before 0.7.0
rm -rf "/Applications/CPU Sentinel.app"
# A copy someone installed in their own ~/Applications would start at login beside this one.
for old in /Users/*/Applications/"System Sentinel.app"; do
    [ -d "$old" ] || continue
    [ "$(defaults read "$old/Contents/Info" CFBundleIdentifier 2>/dev/null)" = consulting.cloudscale.systemsentinel ] && rm -rf "$old"
done
exit 0
EOF
cat > "$WORK/scripts/postinstall" <<'EOF'
#!/bin/bash
# Start the new copy for whoever is logged in at the screen; at the login window, the login
# item (MDM profile) starts it at the next login.
APP="/Applications/System Sentinel.app"
USER_NOW="$(stat -f %Su /dev/console)"
if [ -n "$USER_NOW" ] && [ "$USER_NOW" != root ] && [ "$USER_NOW" != loginwindow ]; then
    UID_NOW="$(id -u "$USER_NOW")"
    launchctl asuser "$UID_NOW" sudo -u "$USER_NOW" /usr/bin/open -g "$APP" || true
fi
exit 0
EOF
chmod 755 "$WORK/scripts/preinstall" "$WORK/scripts/postinstall"

SIGN_ARGS=()
INSTALLER_ID=""
if [[ -n "$SENTINEL_PUBLISHER_TEAM" ]]; then
    INSTALLER_ID="$(security find-identity -v 2>/dev/null | sed -n "s/.*\"\(Developer ID Installer: .*($SENTINEL_PUBLISHER_TEAM)\)\"/\1/p" | head -1)"
    [[ -n "$INSTALLER_ID" ]] || { echo "!! no Developer ID Installer certificate for team $SENTINEL_PUBLISHER_TEAM, not packaging" >&2; exit 1; }
    SIGN_ARGS=(--sign "$INSTALLER_ID" --timestamp)
fi

rm -f "$PKG"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --scripts "$WORK/scripts" --install-location / \
    --identifier consulting.cloudscale.systemsentinel.pkg --version "$VERSION" \
    ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$PKG" >/dev/null

if [[ -n "$INSTALLER_ID" ]]; then
    echo "== notarise pkg"
    xcrun notarytool submit "$PKG" --keychain-profile "${NOTARY_PROFILE:-system-sentinel}" --wait
    xcrun stapler staple "$PKG"
    pkgutil --check-signature "$PKG" | sed -n '1,3p'
    spctl --assess --type install --verbose "$PKG"
else
    echo "   unsigned package (no Developer ID yet)"
fi

# What is inside, checked rather than assumed.
FILES="$(pkgutil --payload-files "$PKG")"
[[ "$FILES" == *"./Applications/System Sentinel.app/Contents/MacOS/SystemSentinel"* ]] \
    || { echo "!! $PKG does not contain the app in /Applications" >&2; exit 1; }
echo "== $PKG ($(du -h "$PKG" | cut -f1))"
