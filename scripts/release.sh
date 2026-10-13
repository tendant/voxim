#!/usr/bin/env bash
# Build, notarize and publish a voxim release as a DMG on GitHub.
#
#   scripts/release.sh 0.1.0            full release (asks before tagging and publishing)
#   scripts/release.sh 0.1.0 --dry-run  build, package and sign the DMG; skip notarization and publishing
#   scripts/release.sh 0.1.0 --yes      publish without the final prompt (non-interactive use)
#
# One-time setup (stores notarization credentials in the keychain):
#   xcrun notarytool store-credentials voxim-notary \
#     --apple-id <Apple ID> --team-id WJTDTA46K5 --password <app-specific password>
set -euo pipefail

TEAM_ID="${VOXIM_TEAM_ID:-WJTDTA46K5}"
NOTARY_PROFILE="${VOXIM_NOTARY_PROFILE:-voxim-notary}"
REPO="tendant/voxim"

VERSION="${1:-}"
DRY_RUN=false
ASSUME_YES=false
for arg in "${@:2}"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes) ASSUME_YES=true ;;
        *) echo "usage: $0 <major.minor.patch> [--dry-run] [--yes]" >&2; exit 2 ;;
    esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <major.minor.patch> [--dry-run] [--yes]" >&2
    exit 2
fi
TAG="v$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Release/voxim.app"
OUT="$ROOT/build/release"
STAGE="$OUT/dmg-root"
DMG="$OUT/voxim-$VERSION.dmg"
NOTES="$ROOT/docs/release-notes/$TAG.md"

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

step "Preflight"
cd "$ROOT"
if ! $DRY_RUN; then
    [[ -z "$(git status --porcelain)" ]] || fail "working tree has uncommitted changes; the release must match a commit"
    git fetch -q origin
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "HEAD is not origin/main; push or pull first"
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
    [[ -f "$NOTES" ]] || fail "missing release notes: ${NOTES#$ROOT/}"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "no notarization credentials in profile '$NOTARY_PROFILE' (see the setup command at the top of this script)"
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
fi
IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="$(grep -o "\"Developer ID Application: .*($TEAM_ID)\"" <<<"$IDENTITIES" | head -1 | tr -d '"' || true)"
[[ -n "$IDENTITY" ]] || fail "no Developer ID Application identity for team $TEAM_ID"
echo "    $TAG at $(git rev-parse --short HEAD), signing as $IDENTITY"

step "Building app"
rm -rf "$ROOT/build/DerivedData"
VOXIM_VERSION="$VERSION" "$ROOT/scripts/install.sh" --build-only
# Capture first: `cmd | grep -q` can SIGPIPE cmd and trip pipefail.
APP_SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -q "^Timestamp=" <<<"$APP_SIGNATURE" || fail "app signature has no secure timestamp (required for notarization)"
SHORT_VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
[[ "$SHORT_VERSION" == "$VERSION" ]] || fail "built app reports version $SHORT_VERSION, expected $VERSION"

step "Packaging DMG"
rm -rf "$OUT"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/voxim.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "voxim $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
echo "    $(du -h "$DMG" | cut -f1) $DMG"

if $DRY_RUN; then
    step "Dry run: stopping before notarization"
    exit 0
fi

step "Notarizing (usually 1-5 minutes)"
SUBMISSION="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
STATUS="$(plutil -extract status raw - <<<"$SUBMISSION" 2>/dev/null || echo unknown)"
SUBMISSION_ID="$(plutil -extract id raw - <<<"$SUBMISSION" 2>/dev/null || echo unknown)"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization status: $STATUS. Log:" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
fi
echo "    accepted (submission $SUBMISSION_ID)"

step "Stapling and verifying"
xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null \
    || fail "Gatekeeper rejects the DMG"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    sha256 $SHA256"

step "Ready to publish $TAG"
echo "    DMG: $DMG"
echo "    Notes: ${NOTES#$ROOT/}"
if ! $ASSUME_YES; then
    read -r -p "    Tag $TAG and publish the GitHub release? [y/N] " answer || answer=""
    [[ "$answer" == [yY] ]] || { echo "Not published. The notarized DMG is at $DMG"; exit 0; }
fi

git tag -a "$TAG" -m "voxim $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "voxim $VERSION" \
    --notes-file <(cat "$NOTES"; printf '\n---\nSHA-256 `%s`  voxim-%s.dmg\n' "$SHA256" "$VERSION")
echo
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
