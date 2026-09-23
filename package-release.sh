#!/bin/bash
# Build a reproducible, GitHub-uploadable personal release package.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: ./package-release.sh VERSION" >&2
  exit 64
fi

VERSION="${1#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must use MAJOR.MINOR.PATCH format" >&2
  exit 64
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit or stash changes before creating a release package" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$PROJECT_DIR/Resources/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "error: Info.plist version is $PLIST_VERSION, expected $VERSION" >&2
  exit 1
fi

"$PROJECT_DIR/build.sh"

APP="$PROJECT_DIR/build/CodexTouchBar.app"
ARCHIVE_DIR="$PROJECT_DIR/dist"
ARCHIVE="$ARCHIVE_DIR/CodexTouchBar-v$VERSION-macos-arm64.zip"
CHECKSUM="$ARCHIVE.sha256"

codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/CodexTouchBar" --self-test

mkdir -p "$ARCHIVE_DIR"
rm -f "$ARCHIVE" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
(
  cd "$ARCHIVE_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
)

echo "Release package: $ARCHIVE"
echo "Checksum:        $CHECKSUM"
