#!/bin/bash
# Build and install the personal arm64 app without touching Codex credentials.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

APP_NAME="CodexTouchBar.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"

mkdir -p "$TARGET_DIR"
# `open` activates an already-running app instead of loading its newly copied
# executable. Stop only this bundle's executable before replacing it so every
# install reliably runs the version that was just built.
if /usr/bin/pgrep -x "CodexTouchBar" >/dev/null 2>&1; then
  /usr/bin/pkill -x "CodexTouchBar"
  /bin/sleep 0.25
fi
if [[ -d "$TARGET_APP" ]]; then
  INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$INSTALLED_BUNDLE_ID" != "com.wyx.CodexTouchBar" ]]; then
    echo "error: refusing to replace unexpected bundle at $TARGET_APP" >&2
    exit 1
  fi
  rm -rf "$TARGET_APP"
fi
ditto "build/$APP_NAME" "$TARGET_APP"
open -n "$TARGET_APP"
