#!/usr/bin/env bash
# Build a Release voxim signed with Developer ID and install it to /Applications.
#
#   scripts/install.sh               build, install, launch
#   scripts/install.sh --build-only  build and verify the signature, don't install
#
# Signing with the Developer ID identity keeps the app's code-signing requirement stable
# across rebuilds, so macOS keeps the Microphone and Accessibility grants after reinstalling.
set -euo pipefail

TEAM_ID="WJTDTA46K5"
BUNDLE_ID="ai.weilabs.voxim"
INSTALL_PATH="/Applications/voxim.app"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/voxim.app"
BUILD_ONLY=false
[[ "${1:-}" == "--build-only" ]] && BUILD_ONLY=true

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)"; then
    echo "error: no 'Developer ID Application' identity for team $TEAM_ID in the keychain" >&2
    exit 1
fi

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
echo "==> Building voxim (build $BUILD_NUMBER, $COMMIT)"
xcodebuild \
    -project "$ROOT/voxim.xcodeproj" \
    -scheme voxim \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

echo "==> Verifying signature"
codesign --verify --strict --deep "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application: .*($TEAM_ID)" <<<"$SIGNATURE" \
    || { echo "error: app is not signed with Developer ID" >&2; exit 1; }
grep -q "runtime" <<<"$SIGNATURE" \
    || { echo "error: hardened runtime is not enabled" >&2; exit 1; }
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
grep -q "com.apple.security.device.audio-input" <<<"$ENTITLEMENTS" \
    || { echo "error: microphone entitlement missing; recording would be silent" >&2; exit 1; }
if grep -q "get-task-allow" <<<"$ENTITLEMENTS"; then
    echo "error: release build carries the get-task-allow (debugging) entitlement" >&2
    exit 1
fi
echo "    $(grep '^Authority=Developer ID Application' <<<"$SIGNATURE" | head -1)"
echo "    $(du -sh "$APP" | cut -f1) at $APP"

if $BUILD_ONLY; then
    exit 0
fi

if pgrep -qx voxim; then
    echo "==> Quitting running voxim"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -qx voxim || break; sleep 0.25; done
    if pgrep -qx voxim; then
        echo "error: voxim is still running (a copy paused in the Xcode debugger?). Quit it and retry." >&2
        exit 1
    fi
fi

echo "==> Installing to $INSTALL_PATH"
rm -rf "$INSTALL_PATH"
ditto "$APP" "$INSTALL_PATH"

echo "==> Launching"
open "$INSTALL_PATH"
echo "Done. First launch asks for Accessibility (and Microphone on first dictation)."
