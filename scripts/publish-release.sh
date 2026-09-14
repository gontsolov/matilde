#!/bin/bash
set -euo pipefail
: "${MATILDE_VERSION:?}" "${GITHUB_SHA:?}"
TAG="v$MATILDE_VERSION"
OUT="build/releases/$MATILDE_VERSION"
cat > build/release-notes.md <<'NOTES'
## Download

Download **Matilde.dmg**, open it, and drag Matilde into Applications.
Supports Apple silicon Macs (M1 or later) running macOS 14 or later.
Intel Macs can continue using Matilde 0.1.8.

## Updates

Matilde checks for new versions and offers to install them. You can also use **Matilde → Check for Updates…**. Updates and the update feed are verified using Matilde's signing key.
NOTES
if [[ -f "release-notes/$MATILDE_VERSION.md" ]]; then
    printf '\n' >> build/release-notes.md
    cat "release-notes/$MATILDE_VERSION.md" >> build/release-notes.md
fi
if [[ "${SIGN_WITH_APPLE:-}" != true ]]; then
    cat >> build/release-notes.md <<'NOTES'

## First launch

This early release is not Apple-notarized or Developer ID signed. macOS may block its first launch. If you trust this build, follow [Apple's instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac). Managed Macs may not allow it.
NOTES
fi
if [[ "${RELEASE_EXISTS:-false}" != true ]]; then
    gh release create "$TAG" --draft --target "$GITHUB_SHA" --title "Matilde $MATILDE_VERSION" --notes-file build/release-notes.md
fi
# Keep the previous latest feed live until every new asset is uploaded.
gh release upload "$TAG" "$OUT/Matilde.dmg" "$OUT/appcast.xml" "$OUT/SHA256SUMS" --clobber
gh release edit "$TAG" --draft=false --latest --notes-file build/release-notes.md
