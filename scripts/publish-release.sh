#!/usr/bin/env bash
# Builds, tags and publishes a GitHub release with every file the website and blog link to.
#
#   bash scripts/publish-release.sh NOTES.md
#
# Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist and commit first.
# Uploads the zip (install.sh), the versioned .dmg and System-Sentinel.dmg, which the
# releases/latest/download link on cloudscale.consulting and andrewbaker.ninja serves, then
# fetches that link to prove it now gives this version's .dmg.
# Then puts both .dmg files on S3 (andrewninjawordpress, public) and checks what is served.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES="${1:?usage: publish-release.sh NOTES.md}"
[[ -f "$NOTES" ]] || { echo "no notes file: $NOTES" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
[[ "$(git branch --show-current)" == main ]] || { echo "not on main" >&2; exit 1; }
git diff --quiet HEAD -- Sources Resources Package.swift scripts || { echo "uncommitted changes in the app, commit first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists, bump the version" >&2; exit 1; }

# S3 comes last, so find out now, before anything is tagged, whether it would work.
AWS_ARGS=(--region af-south-1)
if aws configure list-profiles 2>/dev/null | grep -qx personal; then AWS_ARGS+=(--profile personal); fi
aws sts get-caller-identity "${AWS_ARGS[@]}" >/dev/null 2>&1 || { echo "AWS credentials do not work, the S3 upload would fail" >&2; exit 1; }

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
# GitHub can serve the previous release's file for up to a minute or two after creating this one.
want=$(stat -f%z "$LATEST")
for _ in $(seq 1 18); do
  served=$(curl -fsIL "$URL" | awk 'tolower($1)=="content-length:" {n=$2} END {print n+0}')
  [[ "$served" == "$want" ]] && break
  sleep 10
done
[[ "$served" == "$want" ]] || { echo "!! $URL serves $served bytes, expected $want" >&2; exit 1; }
echo "== $TAG published; $URL serves it"

# The same .dmg files on S3, public, beside the plugin zips. Each one is downloaded again
# and compared, because "upload: ..." proves a transfer, not what is served.
BUCKET="andrewninjawordpress"
REGION="af-south-1"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sentinel-s3-XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
for f in "$DMG" "$LATEST"; do
  KEY="$(basename "$f")"
  aws s3 cp "$f" "s3://$BUCKET/$KEY" "${AWS_ARGS[@]}" --acl public-read \
    --content-type application/x-apple-diskimage --only-show-errors
  S3URL="https://$BUCKET.s3.$REGION.amazonaws.com/$KEY"
  curl -sf -o "$CHECK_DIR/$KEY" "$S3URL?v=$VERSION" || { echo "!! $S3URL did not download after the upload" >&2; exit 1; }
  [[ "$(shasum -a 256 < "$f")" == "$(shasum -a 256 < "$CHECK_DIR/$KEY")" ]] \
    || { echo "!! $S3URL does not serve the file just uploaded" >&2; exit 1; }
  echo "== $S3URL serves it"
done
