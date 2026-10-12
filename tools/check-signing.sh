#!/bin/bash
# Regression: changed code must retain the same certificate-bound identity.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
FIXTURE_DIR="$(mktemp -d "$PWD/build/signing-check-XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
for version in 1 2; do
    printf 'int main(void) { return %s; }\n' "$version" > "$FIXTURE_DIR/v$version.c"
    /usr/bin/clang "$FIXTURE_DIR/v$version.c" -o "$FIXTURE_DIR/v$version"
    ./tools/sign-app.sh "$FIXTURE_DIR/v$version"
done
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p'; }
OLD_REQUIREMENT="$(requirement "$FIXTURE_DIR/v1")"
NEW_REQUIREMENT="$(requirement "$FIXTURE_DIR/v2")"
if [[ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]]; then
    echo "error: code update changed the designated requirement" >&2
    exit 1
fi
OLD_HASH="$(codesign -d -vvv "$FIXTURE_DIR/v1" 2>&1 | sed -n 's/^CDHash=//p')"
NEW_HASH="$(codesign -d -vvv "$FIXTURE_DIR/v2" 2>&1 | sed -n 's/^CDHash=//p')"
if [[ -z "$OLD_HASH" || "$OLD_HASH" == "$NEW_HASH" ]]; then
    echo "error: fixture did not change executable content" >&2
    exit 1
fi
codesign --verify --strict -R "=$OLD_REQUIREMENT" "$FIXTURE_DIR/v2"
cp "$FIXTURE_DIR/v2" "$FIXTURE_DIR/same-id-adhoc"
codesign --force --sign - --identifier com.wyx.CodexTouchBar "$FIXTURE_DIR/same-id-adhoc" >/dev/null 2>&1
if codesign --verify --strict -R "=$OLD_REQUIREMENT" "$FIXTURE_DIR/same-id-adhoc" >/dev/null 2>&1; then
    echo "error: same identifier without the certificate satisfied the signing identity" >&2
    exit 1
fi
cp "$FIXTURE_DIR/v2" "$FIXTURE_DIR/tampered"
printf '\001' | dd of="$FIXTURE_DIR/tampered" bs=1 seek=4096 conv=notrunc 2>/dev/null
if codesign --verify --strict "$FIXTURE_DIR/tampered" >/dev/null 2>&1; then
    echo "error: tampered executable still validates" >&2
    exit 1
fi
echo "Signing regression passed: changed code retains identity; ad-hoc impostor and tampered code rejected."
