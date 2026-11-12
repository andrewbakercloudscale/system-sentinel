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
if [[ -z "${SENTINEL_SIGN_ID:-}" ]]; then
    SENTINEL_SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk '/^ *[0-9]+\) [0-9A-F]{40} / {print $2; exit}')"
fi
SENTINEL_SIGN_ID="${SENTINEL_SIGN_ID:--}"
