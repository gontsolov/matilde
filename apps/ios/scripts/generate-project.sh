#!/bin/bash
# Writes apps/ios/Matilde.xcodeproj from project.yml. Needs XcodeGen (`brew install xcodegen`).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml
echo "Open apps/ios/Matilde.xcodeproj in Xcode 26 or later."
