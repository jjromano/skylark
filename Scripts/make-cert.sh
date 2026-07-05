#!/usr/bin/env bash
#
# make-cert.sh — create the self-signed "Skylark Dev Signing" codesigning
# identity once, so TCC grants (Mic, Accessibility, Input Monitoring) survive
# rebuilds. Idempotent. Needs root to add the cert as trusted.
#
# Pattern adapted from Electron's CI self-signed codesigning recipe.

set -euo pipefail

IDENTITY="Skylark Dev Signing"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "✓ Codesigning identity '$IDENTITY' already exists."
    security find-identity -v -p codesigning | grep "$IDENTITY" || true
    exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
    cat <<EOF
This script must run as root to add a trusted self-signed certificate.

Run:
    sudo Scripts/make-cert.sh

It will create a self-signed codesigning identity named "$IDENTITY" and add it
to the System keychain as trusted for code signing.
EOF
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CONFIG="$WORKDIR/cert.conf"
cat > "$CONFIG" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $IDENTITY

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

KEY="$WORKDIR/skylark.key"
CRT="$WORKDIR/skylark.crt"
P12="$WORKDIR/skylark.p12"

echo "→ Generating self-signed codesigning certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" \
    -days 3650 -config "$CONFIG"

# Bundle into a PKCS#12 with no password for import.
openssl pkcs12 -export -inkey "$KEY" -in "$CRT" \
    -out "$P12" -passout pass:

echo "→ Importing identity into the System keychain…"
security import "$P12" -k /Library/Keychains/System.keychain \
    -P "" -T /usr/bin/codesign -A

echo "→ Trusting the certificate for code signing…"
security add-trusted-cert -d -r trustAsRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$CRT"

echo "✓ Done. Verify with:"
echo "    security find-identity -v -p codesigning"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
