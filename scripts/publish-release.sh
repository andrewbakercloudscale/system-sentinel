#!/usr/bin/env bash
# Builds, tags and publishes a GitHub release with every file the website and blog link to.
#
#   bash scripts/publish-release.sh NOTES.md
#
# Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist and commit first.
# Uploads the zip (install.sh), the versioned .dmg and System-Sentinel.dmg, which the
# releases/latest/download link on cloudscale.consulting and andrewbaker.ninja serves, then
# fetches that link to prove it now gives this version's .dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES="${1:?usage: publish-release.sh NOTES.md}"
[[ -f "$NOTES" ]] || { echo "no notes file: $NOTES" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
[[ "$(git branch --show-current)" == main ]] || { echo "not on main" >&2; exit 1; }
git diff --quiet HEAD -- Sources Resources Package.swift scripts || { echo "uncommitted changes in the app, commit first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists, bump the version" >&2; exit 1; }

bash scripts/release.sh
ZIP="dist/System-Sentinel-$VERSION.zip"
DMG="dist/System-Sentinel-$VERSION.dmg"
LATEST="dist/System-Sentinel.dmg"
for f in "$ZIP" "$DMG" "$LATEST"; do [[ -s "$f" ]] || { echo "missing $f" >&2; exit 1; }; done

git tag "$TAG"
git push -q origin main "$TAG"
gh release create "$TAG" "$ZIP" "$DMG" "$LATEST" --title "$TAG" --notes-file "$NOTES"

# The latest/download link is what people click; check it serves this build.
URL="https://github.com/andrewbakercloudscale/system-sentinel/releases/latest/download/System-Sentinel.dmg"
served=$(curl -fsIL "$URL" | awk 'tolower($1)=="content-length:" {n=$2} END {print n+0}')
want=$(stat -f%z "$LATEST")
[[ "$served" == "$want" ]] || { echo "!! $URL serves $served bytes, expected $want" >&2; exit 1; }
echo "== $TAG published; $URL serves it"
