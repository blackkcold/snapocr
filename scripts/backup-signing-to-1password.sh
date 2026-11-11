#!/bin/bash
# Stores the release signing material in 1Password.
#
# Run once after `scripts/generate-signing-material.sh` (or after restoring the
# material on a new machine). Requires an unlocked session: `op signin`.
#
# The vault holds three items:
#   SnapGlass Code Signing        the .p12 as base64 + its export password
#   SnapGlass EdDSA private key   the 32-byte Sparkle seed (base64)
#   SnapGlass signing notes       fingerprints and recovery instructions
set -euo pipefail

SIGNING_DIR="${SIGNING_DIR:-$HOME/.config/snapglass/signing}"
VAULT="${OP_VAULT:-SnapGlass Release}"

if ! command -v op >/dev/null 2>&1; then
    echo "1Password CLI (op) is not installed." >&2
    exit 1
fi

if ! op whoami >/dev/null 2>&1; then
    echo "1Password CLI is not signed in. Run: op signin" >&2
    exit 1
fi

for file in SnapGlass.p12 SnapGlass.p12.password sparkle_ed25519.key sparkle_ed25519.pub; do
    if [ ! -f "$SIGNING_DIR/$file" ]; then
        echo "Missing $SIGNING_DIR/$file" >&2
        exit 1
    fi
done

if ! op vault get "$VAULT" >/dev/null 2>&1; then
    echo "▸ Creating vault: $VAULT"
    op vault create "$VAULT"
fi

SHA1="$(openssl x509 -in "$SIGNING_DIR/cert.pem" -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//')"
EXPIRES="$(openssl x509 -in "$SIGNING_DIR/cert.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"

echo "▸ Storing certificate and password"
op item create --category password --vault "$VAULT" \
    --title "SnapGlass Code Signing" \
    "password=$(cat "$SIGNING_DIR/SnapGlass.p12.password")" \
    "notes=CN=SnapGlass Code Signing
SHA-1=$SHA1
Expires=$EXPIRES

p12 (base64):
$(base64 < "$SIGNING_DIR/SnapGlass.p12" | tr -d '\n')

Restore: echo <base64> | base64 -D > SnapGlass.p12
Keep this item even after migrating to a Developer ID: the certificate hash
is part of the recorded designated requirement." >/dev/null

echo "▸ Storing Sparkle EdDSA private key"
op item create --category password --vault "$VAULT" \
    --title "Sparkle EdDSA private key" \
    "password=$(cat "$SIGNING_DIR/sparkle_ed25519.key")" \
    "notes=Public key: $(cat "$SIGNING_DIR/sparkle_ed25519.pub")

Losing this key means installed self-signed copies can never be updated
again. Keep at least two offline copies." >/dev/null

echo "✅ Signing material stored in vault \"$VAULT\""
echo "   Verify with: op item list --vault \"$VAULT\""
