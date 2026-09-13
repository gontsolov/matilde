#!/bin/bash
set -euo pipefail
: "${APPLE_CERTIFICATE_P12:?}" "${APPLE_CERTIFICATE_PASSWORD:?}" "${CODE_SIGN_IDENTITY:?}"
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
security import "$RUNNER_TEMP/matilde-signing.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
printf 'CODE_SIGN_IDENTITY=%s\n' "$CODE_SIGN_IDENTITY" >> "$GITHUB_ENV"
rm "$RUNNER_TEMP/matilde-signing.p12"
