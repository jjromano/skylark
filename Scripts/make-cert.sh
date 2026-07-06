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

# We reach here only when no *valid* (trusted) identity exists. A previous run
# may have imported the cert but died before trusting it (so it's present but
# not "valid"). Remove any such stray/duplicate remnants first — two certs with
# this common name would make `codesign --sign "$IDENTITY"` fail.
echo "→ Clearing any stale '$IDENTITY' remnants from a previous run…"
for _ in 1 2 3 4 5; do
    security delete-identity -c "$IDENTITY" /Library/Keychains/System.keychain >/dev/null 2>&1 || break
done
security delete-certificate -c "$IDENTITY" -t /Library/Keychains/System.keychain >/dev/null 2>&1 || true

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

# Use the system LibreSSL explicitly. A Homebrew/conda OpenSSL 3.x earlier on
# PATH writes PKCS#12 files whose default MAC/PBE algorithms macOS's
# `security import` rejects ("MAC verification failed"); /usr/bin/openssl
# (LibreSSL, always present on macOS) does not.
OPENSSL="/usr/bin/openssl"

# Transport passphrase for the PKCS#12 hand-off into the keychain. NOT a secret
# and never stored — but it must be non-empty: macOS 26's `security import`
# fails MAC verification on an empty-password PKCS#12.
P12_PASS="skylark-dev-transport"

echo "→ Generating self-signed codesigning certificate…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" \
    -days 3650 -config "$CONFIG"

# Bundle into a PKCS#12 for import.
"$OPENSSL" pkcs12 -export -inkey "$KEY" -in "$CRT" \
    -out "$P12" -passout pass:"$P12_PASS"

echo "→ Importing identity into the System keychain…"
security import "$P12" -k /Library/Keychains/System.keychain \
    -P "$P12_PASS" -T /usr/bin/codesign -A

echo "→ Trusting the certificate for code signing…"
# A self-signed cert must use `trustRoot`; `trustAsRoot` is only valid for
# non-self-signed certs and errors with "SecTrustSettingsSetTrustSettings:
# ... parameters ... not valid". Runs under root (sudo), which is the
# authorization the admin trust domain requires. Non-fatal: the identity is
# already imported and codesign-usable, so a trust hiccup shouldn't abort the
# whole install — the build just falls back to ad-hoc signing with a warning.
if ! security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$CRT"; then
    echo "⚠️  Could not set trust on the certificate. The identity is imported" >&2
    echo "   and usable, but the build may sign ad-hoc (permission grants would" >&2
    echo "   then need re-approval after each rebuild). Re-run to retry trust." >&2
fi

echo "✓ Done. Verify with:"
echo "    security find-identity -v -p codesigning"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
