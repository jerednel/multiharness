#!/usr/bin/env bash
# Create a self-signed code-signing certificate the first time it's needed,
# then keep using it across rebuilds. With a stable signing identity:
#   - Keychain ACL prompts stop on every rebuild.
#   - TCC grants (Documents, Local Network, etc.) survive rebuilds.
#   - AppleMobileFileIntegrity stops killing the sidecar when an off-host
#     client (your iPhone) connects.
#
# Idempotent — safe to re-run. Will not produce a cert that's trusted by
# anything outside this machine; that's by design.

set -euo pipefail

CERT_NAME="${MULTIHARNESS_CODESIGN_CN:-Multiharness Dev}"
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
    | awk -F'"' '{print $2}' \
    | grep -Fxq "$CERT_NAME"; then
  echo "==> '$CERT_NAME' already in login keychain"
  exit 0
fi

echo "==> Generating self-signed code-signing certificate '$CERT_NAME'"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
req_extensions = v3_req

[req_distinguished_name]
CN = ${CERT_NAME}

[v3_req]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$TMP/key.pem" \
    -x509 -days 3650 \
    -config "$TMP/openssl.cnf" -extensions v3_req \
    -out "$TMP/cert.pem" >/dev/null 2>&1

P12_PASS="multiharness-temp"
# OpenSSL 3.x generates PKCS12 with an HMAC algorithm macOS' security
# command can't read. -legacy switches to the older, macOS-compatible mode.
# Older OpenSSL versions don't have -legacy; the second invocation is the fallback.
if ! openssl pkcs12 -export -legacy \
       -inkey "$TMP/key.pem" \
       -in    "$TMP/cert.pem" \
       -name  "$CERT_NAME" \
       -password "pass:$P12_PASS" \
       -out   "$TMP/identity.p12" >/dev/null 2>&1; then
  openssl pkcs12 -export \
      -inkey "$TMP/key.pem" \
      -in    "$TMP/cert.pem" \
      -name  "$CERT_NAME" \
      -password "pass:$P12_PASS" \
      -out   "$TMP/identity.p12" >/dev/null 2>&1
fi

echo "==> Importing into login keychain (you may be prompted to allow)"
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

echo "==> Done. Re-run 'bash scripts/build-app.sh' — it will sign with '$CERT_NAME'."
