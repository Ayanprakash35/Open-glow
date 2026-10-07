#!/usr/bin/env bash
# One-time setup: a self-signed "Open Glow Dev" code-signing identity, so every build is signed with
# the same identity and macOS keeps Open Glow's privacy grants (Screen & System Audio Recording,
# Automation) across rebuilds. An ad-hoc signature is the hash of the exact binary, so each rebuild
# otherwise looks like a new app.
#
# The identity lives in its own keychain (not your login keychain), unlocked with a random
# password stored next to it, so builds never stop to ask for your password.
#
# Undo:  security delete-keychain ~/Library/Keychains/openglow-signing.keychain-db
#        (also takes it off the keychain search list)
#        rm -r ~/Library/Application\ Support/Open\ Glow\ Dev\ Signing
set -euo pipefail

NAME="Open Glow Dev"
KEYCHAIN="$HOME/Library/Keychains/openglow-signing.keychain-db"
SUPPORT="$HOME/Library/Application Support/Open Glow Dev Signing"
PASSWORD_FILE="$SUPPORT/keychain-password"

if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
    echo "Already set up: $KEYCHAIN"
    exit 0
fi

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A random password for the dedicated keychain, readable only by you.
openssl rand -hex 24 > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"
KEYCHAIN_PASSWORD="$(cat "$PASSWORD_FILE")"
P12_PASSWORD="$(openssl rand -hex 16)"

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> Creating the $NAME certificate (valid 10 years)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD"

echo "==> Creating its keychain"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# No auto-lock: builds unlock it with the stored password anyway.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the private key without a confirmation dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# codesign only finds identities in keychains on the search list; keep the existing ones first.
EXISTING=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" && "$line" != "$KEYCHAIN" ]] && EXISTING+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${EXISTING[@]}" "$KEYCHAIN"

echo "==> Done. Scripts/build_app.sh now signs with \"$NAME\" automatically."
