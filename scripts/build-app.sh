#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
APP="$PWD/build/Matilde.app"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUILD_FLAGS=(-c release --disable-sandbox -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
if [[ "${BUILD_UNIVERSAL:-0}" == 1 ]]; then
    swift build "${BUILD_FLAGS[@]}" --arch arm64
    ARM_BIN=$(swift build "${BUILD_FLAGS[@]}" --arch arm64 --show-bin-path)
    swift build "${BUILD_FLAGS[@]}" --arch x86_64
    INTEL_BIN=$(swift build "${BUILD_FLAGS[@]}" --arch x86_64 --show-bin-path)
    BIN="$ARM_BIN"
else
    swift build "${BUILD_FLAGS[@]}"
    BIN=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)
fi
# This is exclusively the generated app bundle, never a user's installation.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [[ "${BUILD_UNIVERSAL:-0}" == 1 ]]; then
    lipo -create "$ARM_BIN/Matilde" "$INTEL_BIN/Matilde" -output "$APP/Contents/MacOS/Matilde"
else
    cp "$BIN/Matilde" "$APP/Contents/MacOS/Matilde"
fi
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
if [[ "$SIGN_IDENTITY" != '-' ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sign from the inside out; never use --deep for signing.
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK/Versions/B/$part"
done
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
