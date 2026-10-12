#!/bin/bash
# Use a durable signing identity so macOS permissions can survive app updates.
set -euo pipefail
umask 077

if [[ $# -ne 1 || ! -e "$1" ]]; then
    echo "usage: tools/sign-app.sh APP_OR_EXECUTABLE" >&2
    exit 64
fi
APP="$1"
IDENTIFIER="com.wyx.CodexTouchBar"
SIGNING_IDENTITY="${CODEX_TOUCHBAR_SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN="${CODEX_TOUCHBAR_SIGNING_KEYCHAIN:-}"

# An explicitly provided certificate (for example Developer ID Application)
# takes precedence. Never silently fall back to ad-hoc signing.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "error: ad-hoc signing changes the permission identity on every update" >&2
    exit 1
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_DIR="${CODEX_TOUCHBAR_LOCAL_SIGNING_DIR:-$HOME/Library/Application Support/com.wyx.CodexTouchBar/Signing}"
    SIGNING_KEYCHAIN="$SIGNING_DIR/local-signing.keychain-db"
    PASSWORD_FILE="$SIGNING_DIR/keychain-password"
    CERTIFICATE_FILE="$SIGNING_DIR/certificate.pem"
    if [[ ! -d "$SIGNING_DIR" ]]; then
        echo "error: no persistent signing identity; run ./tools/setup-local-signing.sh once" >&2
        exit 1
    fi
    # An incomplete identity must be repaired, not regenerated: regeneration
    # would reproduce the exact permission bug this script prevents.
    if [[ ! -f "$SIGNING_KEYCHAIN" || ! -f "$PASSWORD_FILE" || ! -f "$CERTIFICATE_FILE" ]]; then
        echo "error: incomplete local signing identity at $SIGNING_DIR; restore it from backup" >&2
        exit 1
    fi
    chmod 700 "$SIGNING_DIR"
    chmod 600 "$SIGNING_KEYCHAIN" "$PASSWORD_FILE" "$CERTIFICATE_FILE"
    SIGNING_IDENTITY="$(/usr/bin/openssl x509 -in "$CERTIFICATE_FILE" -noout -fingerprint -sha1 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':')"
    SIGNING_PASSWORD="$(cat "$PASSWORD_FILE")"
    /usr/bin/security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN"
    if ! /usr/bin/security verify-cert -c "$CERTIFICATE_FILE" -p codeSign >/dev/null 2>&1; then
        /usr/bin/security lock-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
        echo "error: local certificate is not trusted for code signing; run ./tools/setup-local-signing.sh" >&2
        exit 1
    fi
    # codesign needs the identity's keychain on the search list even when
    # --keychain selects it explicitly. Restore the user's list afterwards.
    PRIOR_KEYCHAINS=()
    while IFS= read -r path; do
        path="$(printf '%s' "$path" | /usr/bin/sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        [[ -z "$path" ]] || PRIOR_KEYCHAINS+=("$path")
    done < <(/usr/bin/security list-keychains -d user)
    cleanup_signing() {
        /usr/bin/security list-keychains -d user -s "${PRIOR_KEYCHAINS[@]}" >/dev/null 2>&1 || true
        /usr/bin/security lock-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
    }
    trap cleanup_signing EXIT
    /usr/bin/security list-keychains -d user -s "${PRIOR_KEYCHAINS[@]}" "$SIGNING_KEYCHAIN"
fi

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$IDENTIFIER")
if [[ -z "${CODEX_TOUCHBAR_SIGNING_IDENTITY:-}" ]]; then SIGN_ARGS+=(--timestamp=none); fi
if [[ -n "$SIGNING_KEYCHAIN" ]]; then SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --strict "$APP"
REQUIREMENT="$(/usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n 's/^#\{0,1\} *designated => //p')"
if [[ "$REQUIREMENT" != *"certificate"* && "$REQUIREMENT" != *"anchor"* ]]; then
    echo "error: signature has no certificate-bound permission identity" >&2
    exit 1
fi
if [[ "$REQUIREMENT" == *"cdhash"* ]]; then
    echo "error: permission identity still depends on the changing executable hash" >&2
    exit 1
fi
echo "==> signed with stable certificate identity"
