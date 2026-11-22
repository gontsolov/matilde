#!/bin/bash
# One-time, on the owner's Mac: checks an exported Apple signing certificate (.p12) and stores it
# as the GitHub secrets the Release workflow signs with (APPLE_CERTIFICATE_P12,
# APPLE_CERTIFICATE_PASSWORD). From then on every release has the same designated requirement,
# so "Always Allow" in the Keychain dialog survives updates. See docs/releases.md, "Release signing".
#
#   bash apps/macos/scripts/setup-release-signing.sh ~/Desktop/Matilde-signing.p12
#
# Run it again with a renewed certificate (same Apple team) or a Developer ID certificate later.
set -euo pipefail
REPO="${MATILDE_REPO:-gontsolov/matilde}"
P12="${1:-}"
if [[ -z "$P12" || ! -f "$P12" ]]; then
    cat >&2 <<'HELP'
Usage: setup-release-signing.sh <certificate.p12>

Make the certificate first (no paid Apple Developer Program needed for Apple Development):
  1. Xcode > Settings > Accounts > + > Apple ID, and sign in (a free "Personal Team" is fine).
  2. Select the team > Manage Certificates > + > Apple Development.
  3. Keychain Access > login > My Certificates: right-click "Apple Development: …" > Export…,
     save as Matilde-signing.p12 and choose a password.
Then run this script with that file. A Developer ID Application certificate works the same way.
HELP
    exit 1
fi
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
gh auth status >/dev/null || { echo "Sign in to the GitHub CLI first: gh auth login" >&2; exit 1; }
read -rsp "Password of $(basename "$P12"): " PASSWORD; echo

# Check the file signs code with an Apple team, in a throwaway keychain (the login keychain is untouched).
TMP=$(mktemp -d)
KEYCHAIN="$TMP/check.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
trap 'security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -P "$PASSWORD" -f pkcs12 -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null \
    || { echo "Couldn't open $P12 with that password." >&2; exit 1; }
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/^ *1\)/ {print $2}')
NAME=$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/^ *1) [0-9A-F]* "\(.*\)".*/\1/p')
[[ -n "$IDENTITY" ]] || { echo "No code-signing identity (certificate and private key) in $P12." >&2; exit 1; }
cp /usr/bin/true "$TMP/probe"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$TMP/probe" >/dev/null 2>&1 \
    || { echo "codesign couldn't use \"$NAME\". Is Xcode installed (it brings Apple's intermediate certificates)?" >&2; exit 1; }
TEAM_ID=$(codesign -dv --verbose=2 "$TMP/probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ -z "$TEAM_ID" || "$TEAM_ID" == 'not set' ]]; then
    echo "\"$NAME\" has no Apple team (self-signed?). It wouldn't stop the Keychain prompts; use an Apple Development or Developer ID certificate." >&2
    exit 1
fi
echo "Certificate: $NAME"
echo "Apple team:  $TEAM_ID"
echo "Expires:     $(security find-certificate -c "$NAME" -p "$KEYCHAIN" | openssl x509 -noout -enddate | sed 's/notAfter=//')"
read -rp "Store it as the release signing certificate of $REPO? [y/N] " ANSWER
[[ "$ANSWER" == [yY]* ]] || { echo "Nothing changed."; exit 0; }

base64 -i "$P12" | gh secret set APPLE_CERTIFICATE_P12 --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO"
if gh variable list --repo "$REPO" 2>/dev/null | grep -q '^CODE_SIGN_IDENTITY'; then
    echo "Note: the repository variable CODE_SIGN_IDENTITY is set and overrides this certificate's identity."
    echo "      Remove it unless it names this certificate: gh variable delete CODE_SIGN_IDENTITY --repo $REPO"
fi
echo "Done. The next release is signed for team $TEAM_ID. You can delete $P12 now (keep the certificate in your keychain)."
