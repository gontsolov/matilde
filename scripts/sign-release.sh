#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Matilde.app/Contents/Info.plist)
OUT="$PWD/build/releases/$VERSION"
REPOSITORY=$(python3 -c 'import json; print(json.load(open("Config/release.json"))["repository"])')
ARGS=(--download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" --maximum-deltas 0 "$OUT")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # Pipe the key, never pass it as a command-line argument or echo it to logs.
    printf '%s' "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file - "${ARGS[@]}"
else
    .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account app.matilde.local "${ARGS[@]}"
fi
python3 scripts/verify-appcast.py "$OUT/appcast.xml" "$VERSION"
