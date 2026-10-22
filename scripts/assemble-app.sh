#!/usr/bin/env bash
set -euo pipefail

# assemble-app.sh BINARY APP VERSION MIN_MACOS
#
# Builds Gearbox.app at APP around a binary swift has built: the executable,
# the icon, and the Info.plist. It does not sign.
#
# build.sh and release.sh both call it, so the bundle a local build makes and
# the bundle a release ships are the same bundle: one list of Info.plist keys,
# not two that drift.

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 BINARY APP VERSION MIN_MACOS" >&2
    exit 2
fi

BINARY=$1
APP_PATH=$2
VERSION=$3
MIN_MACOS=$4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Gearbox"
BUNDLE_ID="io.github.sevmorris.Gearbox"
ICON="$ROOT/assets/AppIcon.icns"

[[ -x "$BINARY" ]] || { echo "No executable at $BINARY" >&2; exit 1; }

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"
[[ -f "$ICON" ]] || { echo "No icon at ${ICON#"$ROOT"/} — run tools/icon/make-appicon.py" >&2; exit 1; }
cp "$ICON" "$APP_PATH/Contents/Resources/AppIcon.icns"

# A window app, so no LSUIElement. NSAppleEventsUsageDescription: the Login
# Items pane runs mrk's sync-login-items, which asks System Events for the
# login items with AppleScript, and macOS holds Gearbox responsible for that
# request. Without the key, macOS refuses it without asking. release.sh checks
# for it, and for the entitlement the hardened runtime needs as well.
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Gearbox runs mrk's sync-login-items, which asks System Events for your login items.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Seven Morris. MIT License.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
