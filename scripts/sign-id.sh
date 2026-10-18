# Sourced by build-app.sh and release.sh. Picks the identity to sign with.
#
# macOS remembers permissions (Full Disk Access, Automation, folders) per code signature.
# An ad-hoc signature changes with every build, so every update loses them. Any stable
# certificate keeps them: SENTINEL_SIGN_ID, else the first local code signing identity,
# else ad-hoc as a last resort.
if [[ -z "${SENTINEL_SIGN_ID:-}" ]]; then
    SENTINEL_SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $2; exit}')"
fi
SENTINEL_SIGN_ID="${SENTINEL_SIGN_ID:--}"
