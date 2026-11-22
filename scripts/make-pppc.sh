#!/usr/bin/env bash
# Writes a privacy (PPPC) profile for MDM that pre-approves what System Sentinel asks for,
# tied to the signature of the app it is given, so only that publisher's builds get it.
#
#   bash scripts/make-pppc.sh                               # build/System Sentinel.app
#   bash scripts/make-pppc.sh "/Applications/System Sentinel.app" --full-disk-access
#
# Writes dist/SystemSentinel-Privacy.mobileconfig. Works with today's self-signed builds (the
# requirement names the certificate) and with Developer ID builds (it names the Team ID):
# make a new one after the switch, since the old one will not match the new signer.
#
# Approves Apple Events to Finder (empty the Trash), Google Chrome (its tabs) and System
# Events (bring a Chrome tab forward). Never Terminal: approving it would let the app run any
# shell command without anyone seeing a prompt. Full Disk Access only with --full-disk-access,
# for the Storage tab to size folders the person has not opened yet.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/System Sentinel.app"
FDA=0
for a in "$@"; do
    case "$a" in
        --full-disk-access) FDA=1 ;;
        *) APP="$a" ;;
    esac
done
[[ -d "$APP" ]] || { echo "no app at $APP" >&2; exit 1; }
BUNDLE="consulting.cloudscale.systemsentinel"
[[ "$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleIdentifier)" == "$BUNDLE" ]] || { echo "$APP is not System Sentinel" >&2; exit 1; }

# The designated requirement, exactly as macOS will check it.
REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$REQ" ]] || { echo "!! $APP has no designated requirement (ad-hoc signed?)" >&2; exit 1; }
[[ "$REQ" == *"certificate leaf"* ]] || { echo "!! requirement does not name a certificate: $REQ" >&2; exit 1; }

# Each receiver's requirement, read from the app on this Mac when it is installed.
receiver_req() {
    local path="$1" fallback="$2"
    if [[ -d "$path" ]]; then codesign -d -r- "$path" 2>&1 | sed -n 's/^designated => //p'; else echo "$fallback"; fi
}
FINDER_REQ="$(receiver_req /System/Library/CoreServices/Finder.app 'identifier "com.apple.finder" and anchor apple')"
EVENTS_REQ="$(receiver_req /System/Library/CoreServices/System\ Events.app 'identifier "com.apple.systemevents" and anchor apple')"
CHROME_REQ="$(receiver_req "/Applications/Google Chrome.app" 'identifier "com.google.Chrome" and anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV"')"

# sed, not ${s//…}: bash 5.2+ reads & in a replacement as the matched text.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
uuid() { uuidgen; }

event() {
    local rid="$1" rreq="$2"
    cat <<EOF
                    <dict>
                        <key>Identifier</key><string>$BUNDLE</string>
                        <key>IdentifierType</key><string>bundleID</string>
                        <key>CodeRequirement</key><string>$(xml "$REQ")</string>
                        <key>AEReceiverIdentifier</key><string>$rid</string>
                        <key>AEReceiverIdentifierType</key><string>bundleID</string>
                        <key>AEReceiverCodeRequirement</key><string>$(xml "$rreq")</string>
                        <key>Authorization</key><string>Allow</string>
                    </dict>
EOF
}

OUT="dist/SystemSentinel-Privacy.mobileconfig"
mkdir -p dist
{
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Made by scripts/make-pppc.sh. Requirement: $(xml "$REQ") -->
<plist version="1.0">
<dict>
    <key>PayloadType</key><string>Configuration</string>
    <key>PayloadVersion</key><integer>1</integer>
    <key>PayloadIdentifier</key><string>$BUNDLE.privacy</string>
    <key>PayloadUUID</key><string>$(uuid)</string>
    <key>PayloadDisplayName</key><string>System Sentinel privacy</string>
    <key>PayloadDescription</key><string>Lets System Sentinel empty the Trash and list Chrome tabs without asking.</string>
    <key>PayloadOrganization</key><string>Your organisation</string>
    <key>PayloadScope</key><string>System</string>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadIdentifier</key><string>$BUNDLE.privacy.tcc</string>
            <key>PayloadUUID</key><string>$(uuid)</string>
            <key>PayloadDisplayName</key><string>System Sentinel privacy</string>
            <key>Services</key>
            <dict>
                <key>AppleEvents</key>
                <array>
EOF
event com.apple.finder "$FINDER_REQ"
event com.google.Chrome "$CHROME_REQ"
event com.apple.systemevents "$EVENTS_REQ"
echo "                </array>"
if [[ $FDA == 1 ]]; then
cat <<EOF
                <key>SystemPolicyAllFiles</key>
                <array>
                    <dict>
                        <key>Identifier</key><string>$BUNDLE</string>
                        <key>IdentifierType</key><string>bundleID</string>
                        <key>CodeRequirement</key><string>$(xml "$REQ")</string>
                        <key>Authorization</key><string>Allow</string>
                    </dict>
                </array>
EOF
fi
cat <<EOF
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF
} > "$OUT"
plutil -lint -s "$OUT"
echo "== $OUT"
echo "   for: $REQ"
[[ $FDA == 1 ]] && echo "   includes Full Disk Access" || true
