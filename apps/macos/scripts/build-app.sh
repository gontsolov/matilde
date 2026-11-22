#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
APP="$PWD/build/Matilde.app"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUILD_FLAGS=(-c release --disable-sandbox -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
# One supported architecture for local and distribution builds.
swift build "${BUILD_FLAGS[@]}" --arch arm64
BIN=$(swift build "${BUILD_FLAGS[@]}" --arch arm64 --show-bin-path)
# This is exclusively the generated app bundle, never a user's installation.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Matilde" "$APP/Contents/MacOS/Matilde"
ditto "$BIN/Matilde_Matilde.bundle" "$APP/Contents/Resources/Matilde_Matilde.bundle"
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle"
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
ICONSET="$PWD/build/Matilde.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Matilde.icns"
python3 scripts/write-info.py "$APP/Contents/Info.plist"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != '-' ]]; then
    SIGN_FLAGS+=(--timestamp)
    # Hardened Runtime is what notarization needs; the release workflow turns it off for
    # releases that aren't notarized (HARDENED_RUNTIME=0), so nothing else changes for them.
    if [[ "${HARDENED_RUNTIME:-1}" == 1 ]]; then SIGN_FLAGS+=(--options runtime); fi
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sign from the inside out; never use --deep for signing.
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK/Versions/B/$part"
done
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK"
if [[ "$SIGN_IDENTITY" == '-' ]]; then
    codesign "${SIGN_FLAGS[@]}" "$APP"
else
    # A designated requirement that every release signed by the same Apple team meets (Apple
    # Development now, Developer ID later), so macOS treats updates as the same app and Keychain
    # access ("Always Allow") survives them. Ad-hoc builds can't have one: their requirement is
    # the build's own hash. See docs/releases.md, "Release signing".
    TEAM_ID=$(codesign -dv --verbose=2 "$FRAMEWORK" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [[ -z "$TEAM_ID" || "$TEAM_ID" == 'not set' ]]; then
        echo "The signing certificate has no Apple team (self-signed?). macOS would still treat every update as a new app for the Keychain; use an Apple Development or Developer ID certificate." >&2
        exit 1
    fi
    BUNDLE_ID=$(python3 -c 'import json; print(json.load(open("Config/release.json"))["bundleIdentifier"])')
    REQUIREMENT="designated => identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""
    codesign "${SIGN_FLAGS[@]}" --requirements "=$REQUIREMENT" "$APP"
    codesign -d -r- "$APP" 2>&1 | grep -E "leaf\[subject\.OU\] = \"?$TEAM_ID\"?" >/dev/null \
        || { echo "The stable designated requirement was not applied" >&2; exit 1; }
    echo "Signed for team $TEAM_ID with a stable designated requirement"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
