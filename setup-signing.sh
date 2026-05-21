#!/usr/bin/env bash
# One-time setup: create a stable self-signed code-signing identity for VoiceVoice.
# After this runs, every `./build-app.sh` will sign with the same identity, so TCC
# (Accessibility / Automation / Microphone) recognises the rebuilt binary as the
# same app and keeps permissions across rebuilds.
#
# Usage: ./setup-signing.sh
# Idempotent — safe to re-run.

set -euo pipefail

IDENT_NAME="VoiceVoiceDev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENT_NAME\""; then
    echo "Identity \"$IDENT_NAME\" already exists in $KEYCHAIN — nothing to do."
    security find-identity -v -p codesigning "$KEYCHAIN" | grep "$IDENT_NAME"
    exit 0
fi

echo "Creating self-signed code-signing certificate \"$IDENT_NAME\"…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_codesign

[req_distinguished_name]
CN = VoiceVoiceDev

[v3_codesign]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" \
    -out    "$TMP/cert.pem" \
    -days 3650 \
    -config "$TMP/openssl.cnf" >/dev/null 2>&1

P12_PW="voicevoicedev"
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" \
    -in    "$TMP/cert.pem" \
    -out   "$TMP/identity.p12" \
    -name  "$IDENT_NAME" \
    -passout "pass:$P12_PW"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign -A
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

echo
echo "Готово. Установлена identity \"$IDENT_NAME\" в $KEYCHAIN."
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$IDENT_NAME" || true
echo
echo "Если macOS попросит пароль keychain — введи пароль учётной записи."
echo "После этого: ./build-app.sh release, потом сбрось старые TCC-разрешения:"
echo "  tccutil reset Accessibility com.sergekruf.voicevoice"
echo "  tccutil reset AppleEvents  com.sergekruf.voicevoice"
echo "  tccutil reset Microphone   com.sergekruf.voicevoice"
echo "и запусти приложение — заново разреши Микрофон / Accessibility / Automation."
echo "Дальше пересборки больше не будут терять разрешения."
