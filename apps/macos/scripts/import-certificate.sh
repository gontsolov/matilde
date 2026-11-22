#!/bin/bash
# Imports the release signing certificate (APPLE_CERTIFICATE_P12, base64) into a temporary
# keychain for this job and exports CODE_SIGN_IDENTITY for build-app.sh. Works with an Apple
# Development certificate (stable signing without notarization) and a Developer ID Application
# certificate (notarized releases). See docs/releases.md, "Release signing".
set -euo pipefail
: "${APPLE_CERTIFICATE_P12:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
KEYCHAIN="$RUNNER_TEMP/matilde-signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
umask 077
python3 - <<'PY'
import base64, os
from pathlib import Path
Path(os.environ['RUNNER_TEMP'], 'matilde-signing.p12').write_bytes(base64.b64decode(os.environ['APPLE_CERTIFICATE_P12'], validate=True))
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$RUNNER_TEMP/matilde-signing.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -f pkcs12 -A -k "$KEYCHAIN"
rm "$RUNNER_TEMP/matilde-signing.p12"
# Apple's intermediates, so codesign can build the chain whichever certificate this is (public files).
for ca in AppleWWDRCAG3 DeveloperIDG2CA; do
    if curl -fsSL "https://www.apple.com/certificateauthority/$ca.cer" -o "$RUNNER_TEMP/$ca.cer"; then
        security import "$RUNNER_TEMP/$ca.cer" -k "$KEYCHAIN" >/dev/null 2>&1 || true
    else
        echo "Couldn't download $ca; relying on the runner's copy"
    fi
done
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # The certificate's SHA-1, so no identity name needs configuring.
    IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/^ *1\)/ {print $2}')
fi
[[ -n "$IDENTITY" ]] || { echo "No valid code-signing identity in APPLE_CERTIFICATE_P12" >&2; security find-identity -p codesigning "$KEYCHAIN" >&2; exit 1; }
security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/^ *[0-9]*) [0-9A-F]* /Signing identity: /p'
printf 'CODE_SIGN_IDENTITY=%s\n' "$IDENTITY" >> "$GITHUB_ENV"
