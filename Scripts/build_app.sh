#!/usr/bin/env bash
# Builds "Open Glow.app" from the Swift Package and signs it.
# Usage: Scripts/build_app.sh [release|debug]   (release, optimized, by default)
#
# Signing, in order of preference:
#   1. OPENGLOW_SIGN_IDENTITY="<name>" — any code-signing identity in your keychains.
#   2. The "Open Glow Dev" identity from Scripts/setup_signing.sh (one-time), used automatically.
#      A stable identity keeps macOS privacy grants (Screen & System Audio Recording, Automation)
#      across rebuilds.
#   3. Ad-hoc (`codesign -s -`). Its identity is the hash of the exact binary, so every rebuild
#      looks like a different app to macOS privacy settings and grants stop applying.
set -euo pipefail

CONFIG="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Open Glow"
EXECUTABLE="OpenGlow"
BUNDLE_ID="com.openglow.app"
BUILD_DIR="$ROOT_DIR/.build/$CONFIG"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
SIGN_IDENTITY="${OPENGLOW_SIGN_IDENTITY:-}"
DEV_KEYCHAIN="$HOME/Library/Keychains/openglow-signing.keychain-db"
DEV_PASSWORD_FILE="$HOME/Library/Application Support/Open Glow Dev Signing/keychain-password"

echo "==> Building $APP_NAME ($CONFIG)"
swift build --configuration "$CONFIG" --package-path "$ROOT_DIR"

echo "==> Assembling app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with \"$SIGN_IDENTITY\""
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
elif [[ -f "$DEV_KEYCHAIN" && -f "$DEV_PASSWORD_FILE" ]]; then
    SIGN_IDENTITY="Open Glow Dev"
    echo "==> Signing with \"$SIGN_IDENTITY\""
    security unlock-keychain -p "$(cat "$DEV_PASSWORD_FILE")" "$DEV_KEYCHAIN"
    # A self-signed certificate isn't "trusted", and codesign only accepts an untrusted identity by
    # its SHA-1 fingerprint, not by name.
    FINGERPRINT="$(security find-certificate -c "$SIGN_IDENTITY" -Z "$DEV_KEYCHAIN" | awk '/SHA-1 hash:/ {print $3}')"
    codesign --force --sign "$FINGERPRINT" --keychain "$DEV_KEYCHAIN" --identifier "$BUNDLE_ID" "$APP_DIR"
else
    echo "==> Ad-hoc signing"
    codesign --force --sign - "$APP_DIR"
fi

echo "==> Clearing quarantine"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

CDHASH="$(codesign -dvvv "$APP_DIR" 2>&1 | sed -n 's/^CDHash=//p')"
echo "==> Done: $APP_DIR"
echo "    Signature hash: $CDHASH"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "    Ad-hoc build: if Music Sync reports missing Screen Recording access although Open Glow"
    echo "    is enabled in System Settings, reset the stale entry, relaunch, and grant again:"
    echo "      tccutil reset ScreenCapture $BUNDLE_ID"
    echo "    Run Scripts/setup_signing.sh once to keep grants across rebuilds."
fi
echo
echo "Run with (always through open, so macOS checks Open Glow's own permissions):"
echo "  pkill -x $EXECUTABLE; open \"$APP_DIR\""
echo "Watch its log:"
echo "  /usr/bin/log stream --level info --predicate 'subsystem == \"$BUNDLE_ID\"'"
