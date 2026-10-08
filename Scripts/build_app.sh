#!/usr/bin/env bash
# Builds "Open Glow.app" from the Swift Package and signs it.
# Usage: Scripts/build_app.sh [release|debug]   (release, optimized, by default)
#
# Signing, in order of preference:
#   1. OPENGLOW_SIGN_IDENTITY="<name>" — any code-signing identity in your keychains ("-" for ad-hoc).
#   2. The "Open Glow Dev" identity from Scripts/setup_signing.sh (one-time), used automatically.
#      A stable identity keeps macOS privacy grants (Screen & System Audio Recording, Automation)
#      across rebuilds.
#   3. Ad-hoc (`codesign -s -`). Its identity is the hash of the exact binary, so every rebuild
#      looks like a different app to macOS privacy settings and grants stop applying.
# When 1 or 2 is wanted but can't be used, the build says why and signs ad-hoc rather than
# failing after compiling.
#
# Icons: Resources/AppIcon.icns, Resources/MenuBarIcon.png and Resources/MenuBarIcon@2x.png go into
# the bundle when they exist. Scripts/make_icons.sh makes them from your artwork.
set -euo pipefail

CONFIG="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Open Glow"
EXECUTABLE="OpenGlow"
BUNDLE_ID="com.openglow.app"
BUILD_DIR="$ROOT_DIR/.build/$CONFIG"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
REQUESTED_IDENTITY="${OPENGLOW_SIGN_IDENTITY:-}"
DEV_IDENTITY="Open Glow Dev"
DEV_KEYCHAIN="$HOME/Library/Keychains/openglow-signing.keychain-db"
DEV_PASSWORD_FILE="$HOME/Library/Application Support/Open Glow Dev Signing/keychain-password"

warn() {
    echo "WARNING: $*" >&2
}

# Copies Resources/<name> into the bundle. Contents/Resources is made only when something goes in
# it: an empty one fails `codesign --verify --strict`.
add_resource() {
    mkdir -p "$APP_DIR/Contents/Resources"
    cp "$ROOT_DIR/Resources/$1" "$APP_DIR/Contents/Resources/$1"
}

# Sets a string in the bundle's copy of Info.plist (never the source), adding the key if needed.
set_bundle_plist_string() {
    local plist="$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"
}

# Signs the bundle as <identity> (a name, a SHA-1 fingerprint, or "-" for ad-hoc); any further
# arguments go to codesign.
sign_as() {
    local identity="$1"
    shift
    codesign --force --sign "$identity" "$@" --identifier "$BUNDLE_ID" "$APP_DIR"
}

# Signs with the "Open Glow Dev" identity. On failure it puts the reason in FALLBACK_REASON and
# returns 1. Each step is checked by hand: set -e is off inside a function called from `if`.
sign_with_dev_identity() {
    if [[ ! -f "$DEV_KEYCHAIN" ]]; then
        FALLBACK_REASON="its keychain ($DEV_KEYCHAIN) is missing"
        return 1
    fi
    if [[ ! -f "$DEV_PASSWORD_FILE" ]]; then
        FALLBACK_REASON="its keychain password file ($DEV_PASSWORD_FILE) is missing"
        return 1
    fi
    if ! security unlock-keychain -p "$(cat "$DEV_PASSWORD_FILE")" "$DEV_KEYCHAIN" 2>/dev/null; then
        FALLBACK_REASON="its keychain doesn't unlock with the stored password"
        return 1
    fi
    # A self-signed certificate isn't "trusted", and codesign only accepts an untrusted identity by
    # its SHA-1 fingerprint, not by name. find-identity lists only certificates that have their
    # private key, as "  1) <SHA-1> "<name>" (CSSMERR_TP_NOT_TRUSTED)". The listing is captured
    # first so awk never cuts `security` off mid-write (a SIGPIPE would fail the pipeline).
    local identities fingerprint
    identities="$(security find-identity -p codesigning "$DEV_KEYCHAIN" 2>/dev/null)" || identities=""
    fingerprint="$(awk -v name="\"$DEV_IDENTITY\"" \
        'index($0, name) && length($2) == 40 && fp == "" { fp = $2 } END { print fp }' <<< "$identities")"
    if [[ -z "$fingerprint" ]]; then
        FALLBACK_REASON="its keychain has no \"$DEV_IDENTITY\" signing identity"
        return 1
    fi
    if ! sign_as "$fingerprint" --keychain "$DEV_KEYCHAIN"; then
        FALLBACK_REASON="codesign couldn't sign with it (see its message above)"
        return 1
    fi
}

echo "==> Building $APP_NAME ($CONFIG)"
swift build --configuration "$CONFIG" --package-path "$ROOT_DIR"

echo "==> Assembling app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    add_resource AppIcon.icns
    # The name of the .icns in Contents/Resources, without its extension.
    set_bundle_plist_string CFBundleIconFile AppIcon
    echo "    App icon: Resources/AppIcon.icns"
else
    echo "    No Resources/AppIcon.icns; the app gets the generic icon (Scripts/make_icons.sh makes one)"
fi
for icon in MenuBarIcon.png MenuBarIcon@2x.png; do
    if [[ -f "$ROOT_DIR/Resources/$icon" ]]; then
        add_resource "$icon"
        echo "    Menu-bar icon: Resources/$icon"
    fi
done

SIGNED_AS=""        # The identity the bundle ended up signed with; empty means ad-hoc.
FALLBACK_REASON=""  # Why a wanted identity couldn't be used, if it couldn't.

if [[ -n "$REQUESTED_IDENTITY" && "$REQUESTED_IDENTITY" != "-" ]]; then
    echo "==> Signing with \"$REQUESTED_IDENTITY\""
    if sign_as "$REQUESTED_IDENTITY"; then
        SIGNED_AS="$REQUESTED_IDENTITY"
    else
        FALLBACK_REASON="OPENGLOW_SIGN_IDENTITY=\"$REQUESTED_IDENTITY\" couldn't be used (see codesign's"
        FALLBACK_REASON+=" message above; \`security find-identity -p codesigning\` lists your identities)."
    fi
elif [[ -z "$REQUESTED_IDENTITY" && ( -e "$DEV_KEYCHAIN" || -e "$DEV_PASSWORD_FILE" ) ]]; then
    echo "==> Signing with \"$DEV_IDENTITY\""
    if sign_with_dev_identity; then
        SIGNED_AS="$DEV_IDENTITY"
    else
        FALLBACK_REASON="The \"$DEV_IDENTITY\" identity can't be used: $FALLBACK_REASON."
        FALLBACK_REASON+=" Run Scripts/setup_signing.sh to repair it."
    fi
fi

if [[ -z "$SIGNED_AS" ]]; then
    if [[ -n "$FALLBACK_REASON" ]]; then
        warn "$FALLBACK_REASON"
        warn "Signing ad-hoc instead; macOS privacy grants won't carry over to this build."
    fi
    echo "==> Ad-hoc signing"
    sign_as -
fi

echo "==> Clearing quarantine"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

CDHASH="$(codesign -dvvv "$APP_DIR" 2>&1 | sed -n 's/^CDHash=//p')"
echo "==> Done: $APP_DIR"
if [[ -n "$SIGNED_AS" ]]; then
    echo "    Signed with \"$SIGNED_AS\""
elif [[ -n "$FALLBACK_REASON" ]]; then
    echo "    Signed ad-hoc as a fallback (see the warning above)"
else
    echo "    Signed ad-hoc"
fi
echo "    Signature hash: $CDHASH"
if [[ -z "$SIGNED_AS" ]]; then
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
