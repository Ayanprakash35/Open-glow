#!/usr/bin/env bash
# One-time setup: a self-signed "Open Glow Dev" code-signing identity, so every build is signed with
# the same identity and macOS keeps Open Glow's privacy grants (Screen & System Audio Recording,
# Automation) across rebuilds. An ad-hoc signature is the hash of the exact binary, so each rebuild
# otherwise looks like a new app.
#
# The identity lives in its own keychain (not your login keychain), unlocked with a random
# password stored next to it, so builds never stop to ask for your password.
#
# Safe to run again: it does nothing when the identity is in place and works, and starts over when
# an earlier run (or a partial undo) left only part of it behind. Nothing is kept from a run that
# fails partway.
#
# Undo:  security delete-keychain ~/Library/Keychains/openglow-signing.keychain-db
#        (also takes it off the keychain search list)
#        rm -r ~/Library/Application\ Support/Open\ Glow\ Dev\ Signing
set -euo pipefail

NAME="Open Glow Dev"
KEYCHAIN="$HOME/Library/Keychains/openglow-signing.keychain-db"
SUPPORT="$HOME/Library/Application Support/Open Glow Dev Signing"
PASSWORD_FILE="$SUPPORT/keychain-password"
# The new password is written here first and renamed into place only once everything else worked.
PASSWORD_DRAFT="$PASSWORD_FILE.new"

# Unlocks the keychain with the stored password. Fails when either is missing or they don't match.
unlock_keychain() {
    [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]] || return 1
    security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" 2>/dev/null
}

# True when the keychain holds a code-signing identity (certificate plus private key) named $NAME.
# The output is captured before matching: `grep -q` could quit early and, under pipefail, the
# SIGPIPE it leaves `security` with would read as "not found".
has_identity() {
    local identities
    identities="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null)" || return 1
    [[ "$identities" == *"\"$NAME\""* ]]
}

on_search_list() {
    local listing
    listing="$(security list-keychains -d user)" || return 1
    [[ "$listing" == *"\"$KEYCHAIN\""* ]]
}

# codesign only finds identities in keychains on the search list; keep the existing ones first.
add_to_search_list() {
    local listing line
    local existing=()
    # Read the list up front so a failing `security` stops here instead of leaving an empty list,
    # which would then replace the user's whole search list.
    listing="$(security list-keychains -d user)" || return 1
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%\"}"; line="${line#\"}"
        if [[ -n "$line" && "$line" != "$KEYCHAIN" ]]; then
            existing+=("$line")
        fi
    done <<< "$listing"
    # ${a[@]+"${a[@]}"} expands to nothing for an empty array; a plain "${a[@]}" trips set -u on
    # macOS's bash 3.2.
    security list-keychains -d user -s ${existing[@]+"${existing[@]}"} "$KEYCHAIN"
}

# Deletes the keychain file and takes it off the search list. delete-keychain does both; rm is the
# fallback for a file `security` no longer recognizes as a keychain.
remove_keychain() {
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
}

# MARK: - Already set up, or something to repair?

if unlock_keychain && has_identity; then
    if ! on_search_list; then
        echo "==> Putting $KEYCHAIN back on the keychain search list"
        add_to_search_list
    fi
    echo "Already set up: \"$NAME\" in $KEYCHAIN"
    exit 0
fi

if [[ -e "$KEYCHAIN" ]]; then
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        problem="its password file is missing"
    elif ! unlock_keychain; then
        problem="the stored password doesn't unlock it"
    else
        problem="it has no \"$NAME\" signing identity"
    fi
    echo "==> Found a half-finished setup ($problem); removing $KEYCHAIN and starting over."
    echo "    The new identity is a different one, so macOS asks for Open Glow's permissions once more."
    remove_keychain
fi
# A password left from an earlier run matches nothing any more.
rm -f "$PASSWORD_FILE"

# MARK: - Create the identity

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"
WORK="$(mktemp -d)"
CREATED_KEYCHAIN=0
FINISHED=0

# On any failure, take back what this run made, so the next run (and build_app.sh) never sees a
# keychain without its password or identity.
cleanup() {
    rm -rf "$WORK"
    rm -f "$PASSWORD_DRAFT"
    if [[ "$FINISHED" -eq 0 && "$CREATED_KEYCHAIN" -eq 1 && -e "$KEYCHAIN" ]]; then
        echo "==> Setup didn't finish; removing the half-made $KEYCHAIN" >&2
        remove_keychain
    fi
}
trap cleanup EXIT
# Without these, Ctrl-C or a kill would end the script without running the EXIT trap.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# A random password for the dedicated keychain; it reaches the disk only once setup has worked.
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
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
CREATED_KEYCHAIN=1
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# No auto-lock: builds unlock it with the stored password anyway.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the private key without a confirmation dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
if ! has_identity; then
    echo "error: the \"$NAME\" identity didn't show up in $KEYCHAIN after importing it" >&2
    exit 1
fi
if ! on_search_list; then
    add_to_search_list
fi

# Last step: store the password, readable only by you. Written beside its final name and renamed,
# so the file is either complete or absent.
(umask 077 && printf '%s\n' "$KEYCHAIN_PASSWORD" > "$PASSWORD_DRAFT")
mv -f "$PASSWORD_DRAFT" "$PASSWORD_FILE"
FINISHED=1

echo "==> Done. Scripts/build_app.sh now signs with \"$NAME\" automatically."
