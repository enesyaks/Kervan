#!/usr/bin/env bash
# Creates "Kervan Release", the self-signed certificate releases are signed with, in the login keychain.
# Run once on the machine that makes releases: mac/scripts/signing-identity.sh
#
# Why: macOS knows an app by its signature. Ad-hoc signatures change with every build, so after each update the
# app looked like a stranger to the Keychain and lost the saved access key. One certificate across releases keeps
# the app's identity, and the key, from one version to the next. It is not an Apple certificate, so Gatekeeper
# still asks once on first open.
#
# Keep a backup: Keychain Access › My Certificates › "Kervan Release" › Export. A new certificate means every
# installed copy asks for its key once more after the next update.
set -euo pipefail

NAME="${KERVAN_SIGN_IDENTITY:-Kervan Release}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in the keychain."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The Keychain reads only the older PKCS#12 encryption; OpenSSL 3 needs -legacy for it, LibreSSL writes it anyway.
LEGACY=""
if openssl version | grep -q "^OpenSSL 3"; then LEGACY="-legacy"; fi
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export $LEGACY -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the key; macOS may still ask once, the first time it signs (Always Allow).
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". mac/scripts/bundle.sh signs with it from now on."
