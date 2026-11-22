# Sourced by build-app.sh and release.sh. Picks the identity to sign with.
#
# macOS remembers permissions (Full Disk Access, Automation, folders) per code signature.
# An ad-hoc signature changes with every build, so every update loses them. Any stable
# certificate keeps them: SENTINEL_SIGN_ID, else the first local code signing identity,
# else ad-hoc as a last resort.
#
# The identity is picked by its SHA-1 hash and without -v: a self-signed certificate whose
# trust setting was lost (it happened when the login keychain was reset, 2026-11) is listed
# as CSSMERR_TP_NOT_TRUSTED and hidden by -v, but codesign signs with it just the same, and
# the signature's requirement names the certificate's hash, not its trust. Falling back to
# ad-hoc there shipped v0.8.41 with a signature the in-app updater refuses.
# Releases pin the publisher's certificate (release.sh): every installed copy only accepts
# updates signed by it, so signing with any other identity would cut the fleet off updates.
SENTINEL_PUBLISHER_ID="8D7FBBB7FA351E97AEBEA46F65D73E69C1ADAB89"
# The switch to Developer ID (docs/SIGNING.md): set this to the company's 10-character Apple
# Team ID. From then on release.sh signs only with that team's Developer ID Application
# certificate, notarises, and refuses to ship otherwise. Empty: the self-signed publisher.
# install.sh has its own copy of this value, because it runs on its own from GitHub.
SENTINEL_PUBLISHER_TEAM=""
if [[ -z "${SENTINEL_SIGN_ID:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q " $SENTINEL_PUBLISHER_ID "; then
    SENTINEL_SIGN_ID="$SENTINEL_PUBLISHER_ID"
fi
if [[ -z "${SENTINEL_SIGN_ID:-}" ]]; then
    SENTINEL_SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk '/^ *[0-9]+\) [0-9A-F]{40} / {print $2; exit}')"
fi
SENTINEL_SIGN_ID="${SENTINEL_SIGN_ID:--}"
