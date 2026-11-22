#!/usr/bin/env bash
# Says what is in place for Developer ID signing and what is still missing. Changes nothing.
#
#   bash scripts/check-signing.sh            # today's state
#   bash scripts/check-signing.sh TEAMID     # before setting SENTINEL_PUBLISHER_TEAM
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source scripts/sign-id.sh

TEAM="${1:-$SENTINEL_PUBLISHER_TEAM}"
PROFILE="${NOTARY_PROFILE:-system-sentinel}"
missing=0
ok()   { echo "  ok    $1"; }
miss() { echo "  MISS  $1"; missing=$((missing+1)); }

echo "== Today's publisher"
if security find-identity -p codesigning 2>/dev/null | grep -q " $SENTINEL_PUBLISHER_ID "; then
    ok "self-signed certificate ${SENTINEL_PUBLISHER_ID:0:8}… is in the keychain"
else
    echo "  --    self-signed certificate ${SENTINEL_PUBLISHER_ID:0:8}… not in this keychain"
fi
if [[ -n "$SENTINEL_PUBLISHER_TEAM" ]]; then ok "sign-id.sh: SENTINEL_PUBLISHER_TEAM=$SENTINEL_PUBLISHER_TEAM (Developer ID)"
else echo "  --    sign-id.sh: SENTINEL_PUBLISHER_TEAM is empty, releases are self-signed"; fi

echo "== Developer ID${TEAM:+ for team $TEAM}"
IDS="$(security find-identity -v 2>/dev/null)"
APP_ID="$(sed -n "s/.*\"\(Developer ID Application: .*(${TEAM:-[A-Z0-9]*})\)\"/\1/p" <<<"$IDS" | head -1)"
PKG_ID="$(sed -n "s/.*\"\(Developer ID Installer: .*(${TEAM:-[A-Z0-9]*})\)\"/\1/p" <<<"$IDS" | head -1)"
[[ -n "$APP_ID" ]] && ok "$APP_ID" || miss "Developer ID Application certificate (signs the app)"
[[ -n "$PKG_ID" ]] && ok "$PKG_ID" || miss "Developer ID Installer certificate (signs the .pkg)"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    ok "notarisation profile '$PROFILE' works"
else
    miss "notarisation profile '$PROFILE': xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id ${TEAM:-<TEAMID>}"
fi
xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1 && ok "notarytool and stapler (Xcode tools)" || miss "Xcode command line tools: xcode-select --install"

if [[ -n "$TEAM" ]]; then
    echo "== The switch"
    [[ "$SENTINEL_PUBLISHER_TEAM" == "$TEAM" ]] && ok "scripts/sign-id.sh names $TEAM" || miss "scripts/sign-id.sh: SENTINEL_PUBLISHER_TEAM=\"$TEAM\""
    grep -q "^PUBLISHER_TEAM=\"$TEAM\"" install.sh && ok "install.sh names $TEAM" || miss "install.sh: PUBLISHER_TEAM=\"$TEAM\""
fi

echo
if [[ $missing == 0 ]]; then echo "Ready."; else echo "$missing missing; see docs/SIGNING.md."; fi
