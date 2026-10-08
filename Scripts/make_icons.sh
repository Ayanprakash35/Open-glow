#!/usr/bin/env bash
# Builds Open Glow's icons from your artwork, using only tools that ship with macOS.
#
# Usage: Scripts/make_icons.sh <app-icon.png> [<menu-bar-icon.png>]
#   app-icon.png       square, ideally 1024×1024 — becomes Resources/AppIcon.icns
#   menu-bar-icon.png  optional; a black shape on transparency, ideally 36 px tall or more —
#                      becomes Resources/MenuBarIcon.png (18 px tall) and MenuBarIcon@2x.png
#                      (36 px), drawn as a template image that macOS tints to match light and dark
#                      menu bars.
#
# Scripts/build_app.sh copies whichever of these exist into the app bundle on every build, and
# names AppIcon.icns as the bundle's icon (CFBundleIconFile). Delete them to go back to the
# generic icon.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ICON="${1:?Usage: Scripts/make_icons.sh <app-icon.png> [<menu-bar-icon.png>]}"
MENU_ICON="${2:-}"
for input in "$APP_ICON" ${MENU_ICON:+"$MENU_ICON"}; do
    if [[ ! -f "$input" ]]; then
        echo "No such file: $input" >&2
        exit 1
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> App icon from $APP_ICON"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$APP_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z $((size * 2)) $((size * 2)) "$APP_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT_DIR/Resources/AppIcon.icns"
echo "    Resources/AppIcon.icns"

if [[ -n "$MENU_ICON" ]]; then
    echo "==> Menu-bar icon from $MENU_ICON"
    # 18 pt tall is the standard menu-bar glyph height; @2x for Retina displays.
    sips -s format png --resampleHeight 18 "$MENU_ICON" --out "$ROOT_DIR/Resources/MenuBarIcon.png" >/dev/null
    sips -s format png --resampleHeight 36 "$MENU_ICON" --out "$ROOT_DIR/Resources/MenuBarIcon@2x.png" >/dev/null
    echo "    Resources/MenuBarIcon.png, Resources/MenuBarIcon@2x.png"
fi
