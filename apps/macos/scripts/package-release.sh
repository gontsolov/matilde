#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Matilde.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
# Reject accidental Intel or universal builds.
[[ "$(lipo -archs "$APP/Contents/MacOS/Matilde")" == arm64 ]] || { echo "Release executable must be arm64 only" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
OUT="$PWD/build/releases/$VERSION"
STAGE="$PWD/build/dmg-stage"
mkdir -p "$OUT"
notarize() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait --output-format json > "$OUT/notarization-result.json"
    python3 - "$OUT/notarization-result.json" <<'PYTHON'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization failed: {result}")
PYTHON
}
rm -rf "$STAGE"
mkdir -p "$STAGE"
if [[ "${NOTARIZE:-0}" == 1 ]]; then
    : "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
    ditto -c -k --keepParent "$APP" "$OUT/notarization.zip"
    notarize "$OUT/notarization.zip"
    xcrun stapler staple "$APP"
    rm "$OUT/notarization.zip"
fi
ditto "$APP" "$STAGE/Matilde.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Matilde -srcfolder "$STAGE" -ov -format UDZO "$OUT/Matilde.dmg"
if [[ "${NOTARIZE:-0}" == 1 ]]; then
    codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$OUT/Matilde.dmg"
    notarize "$OUT/Matilde.dmg"
    xcrun stapler staple "$OUT/Matilde.dmg"
    xcrun stapler validate "$OUT/Matilde.dmg"
fi
(
    cd "$OUT"
    shasum -a 256 Matilde.dmg > SHA256SUMS
)
echo "Packaged $OUT/Matilde.dmg"
