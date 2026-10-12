#!/bin/bash
# Explicit one-time setup for personal builds. Changes only user code-signing trust.
set -euo pipefail
umask 077

SIGNING_DIR="${CODEX_TOUCHBAR_LOCAL_SIGNING_DIR:-$HOME/Library/Application Support/com.wyx.CodexTouchBar/Signing}"
SIGNING_KEYCHAIN="$SIGNING_DIR/local-signing.keychain-db"
if [[ ! -d "$SIGNING_DIR" ]]; then
    mkdir -p "$(dirname "$SIGNING_DIR")"
    STAGING_DIR="$(mktemp -d "$(dirname "$SIGNING_DIR")/.Signing-XXXXXX")"
    cleanup_setup() {
        if [[ -n "${CREATED_SIGNING_DIR:-}" && -d "$CREATED_SIGNING_DIR" ]]; then
            /usr/bin/security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
            rm -rf "$CREATED_SIGNING_DIR"
        fi
        if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then rm -rf "$STAGING_DIR"; fi
    }
    trap cleanup_setup EXIT
    /usr/bin/openssl rand -base64 48 > "$STAGING_DIR/keychain-password"
    SIGNING_PASSWORD="$(cat "$STAGING_DIR/keychain-password")"
    cat > "$STAGING_DIR/certificate.conf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = CodexTouchBar Local Code Signing
O = CodexTouchBar Personal Build
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
    /usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 7300 \
        -config "$STAGING_DIR/certificate.conf" -keyout "$STAGING_DIR/private-key.pem" \
        -out "$STAGING_DIR/certificate.pem" >/dev/null 2>&1
    /usr/bin/openssl pkcs12 -export -inkey "$STAGING_DIR/private-key.pem" \
        -in "$STAGING_DIR/certificate.pem" -out "$STAGING_DIR/identity.p12" \
        -passout "file:$STAGING_DIR/keychain-password"
    mv "$STAGING_DIR" "$SIGNING_DIR"
    STAGING_DIR=""
    CREATED_SIGNING_DIR="$SIGNING_DIR"
    /usr/bin/security create-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN"
    /usr/bin/security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN"
    /usr/bin/security import "$SIGNING_DIR/identity.p12" -k "$SIGNING_KEYCHAIN" \
        -P "$SIGNING_PASSWORD" -x -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list -S apple-tool:,codesign: -s \
        -k "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
    /usr/bin/security lock-keychain "$SIGNING_KEYCHAIN"
    rm "$SIGNING_DIR/private-key.pem" "$SIGNING_DIR/identity.p12" "$SIGNING_DIR/certificate.conf"
    CREATED_SIGNING_DIR=""
    trap - EXIT
    echo "Created a dedicated, persistent code-signing identity."
fi
for file in local-signing.keychain-db keychain-password certificate.pem; do
    if [[ ! -f "$SIGNING_DIR/$file" ]]; then
        echo "error: incomplete identity at $SIGNING_DIR; restore it rather than generating a new certificate" >&2
        exit 1
    fi
done
chmod 700 "$SIGNING_DIR"
chmod 600 "$SIGNING_DIR"/*
if ! /usr/bin/security verify-cert -c "$SIGNING_DIR/certificate.pem" -p codeSign >/dev/null 2>&1; then
    echo "Adding current-user trust for this certificate's code-signing use only."
    echo "macOS may ask you to approve this certificate trust change."
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign "$SIGNING_DIR/certificate.pem"
fi
/usr/bin/security verify-cert -c "$SIGNING_DIR/certificate.pem" -p codeSign >/dev/null
echo "Local signing is ready. Keep $SIGNING_DIR private and backed up."
