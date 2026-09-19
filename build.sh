#!/bin/bash
# Build CodexTouchBar.app from the Swift Package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CodexTouchBar"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MODULE_CACHE_DIR="$PWD/$BUILD_DIR/.module-cache"

# Keep compiler module caches inside the project. This avoids a stale or
# inaccessible user-level cache from making an otherwise valid local build fail.
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR/swiftpm"

echo "==> swift test"
# Keep protocol parsing and cache behavior covered before assembling the app.
swift test --disable-sandbox

echo "==> swift build -c release"
# --disable-sandbox: manifest compilation sandbox is blocked in some environments.
swift build -c release --disable-sandbox

# Locate the release executable.
EXEC_PATH="$(swift build -c release --disable-sandbox --show-bin-path)/$APP_NAME"
if [[ ! -x "$EXEC_PATH" ]]; then
    echo "error: built executable not found at $EXEC_PATH" >&2
    exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXEC_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Render the simple source SVG at the standard macOS icon sizes and package it
# as an ICNS file. The SVG remains the editable source of truth.
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
ICON_SOURCE="$BUILD_DIR/AppIcon.png"
swift tools/render_app_icon.swift "$ICON_SOURCE"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
swift tools/make_icns.swift "$ICONSET_DIR" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR" "$ICON_SOURCE"

# Ad-hoc sign so the app can be opened without Gatekeeper prompts.
codesign --sign - --force --deep "$APP_BUNDLE" 2>/dev/null || true

echo "==> done"
echo "App: $APP_BUNDLE"
echo "Open with: open \"$APP_BUNDLE\""
