#!/bin/bash
# Build and install the personal arm64 app without touching Codex credentials.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

APP_NAME="CodexTouchBar.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"

mkdir -p "$TARGET_DIR"
MIGRATING_ADHOC=0
if [[ -d "$TARGET_APP" ]]; then
  INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$INSTALLED_BUNDLE_ID" != "com.wyx.CodexTouchBar" ]]; then
    echo "error: refusing to replace unexpected bundle at $TARGET_APP" >&2
    exit 1
  fi
  OLD_REQUIREMENT="$(codesign -d -r- "$TARGET_APP" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')"
  if [[ "$OLD_REQUIREMENT" == *"cdhash"* ]]; then
    MIGRATING_ADHOC=1
  elif [[ -z "$OLD_REQUIREMENT" ]] || ! codesign --verify --strict -R "=$OLD_REQUIREMENT" "build/$APP_NAME" 2>/dev/null; then
    if [[ "${CODEX_TOUCHBAR_ALLOW_SIGNER_CHANGE:-0}" != "1" ]]; then
      echo "error: new build does not match the installed signing identity; refusing to discard permission continuity" >&2
      echo "Restore the original certificate, or explicitly set CODEX_TOUCHBAR_ALLOW_SIGNER_CHANGE=1 for an intentional migration." >&2
      exit 1
    fi
  fi
fi
# `open` activates an already-running app instead of loading its newly copied
# executable. Stop only this bundle's executable before replacing it so every
# install reliably runs the version that was just built.
if /usr/bin/pgrep -x "CodexTouchBar" >/dev/null 2>&1; then
  /usr/bin/pkill -x "CodexTouchBar"
  /bin/sleep 0.25
fi
if [[ "$MIGRATING_ADHOC" == "1" ]]; then
  echo "==> migrating from ad-hoc signing; Accessibility needs one final authorization"
  # Reset this app's stale grant once. Normal certificate-signed updates
  # never reset TCC and do not alter other apps' permissions.
  if ! /usr/bin/tccutil reset Accessibility com.wyx.CodexTouchBar; then
    echo "warning: remove the old CodexTouchBar Accessibility entry and add the installed app once" >&2
  fi
fi
if [[ -d "$TARGET_APP" ]]; then rm -rf "$TARGET_APP"; fi
ditto "build/$APP_NAME" "$TARGET_APP"
open -n "$TARGET_APP"
