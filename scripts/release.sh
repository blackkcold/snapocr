#!/bin/bash
# Builds the local release assets into a GitHub Release.
#
# Expects `scripts/build.sh --dmg --sign` to have produced
#   release/vX.Y.Z/SnapGlass-vX.Y.Z.dmg and its .sha256 sidecar.
#
# Assets published:
#   SnapGlass-vX.Y.Z.dmg            the signed app
#   SnapGlass-vX.Y.Z.dmg.sha256     payload checksum
#   SnapGlass-update.json           legacy manifest for clients before 1.5.0
#   appcast.xml                     Sparkle feed
#   release-notes.md                release body
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=$(tr -d '[:space:]' < version.txt)
BUILD=$(tr -d '[:space:]' < build.txt)
TAG="v${VERSION}"
RELEASE_DIR="release/${TAG}"
DMG_FILE="${RELEASE_DIR}/SnapGlass-v${VERSION}.dmg"
APPCAST_FILE="${RELEASE_DIR}/appcast.xml"
UPDATE_MANIFEST="${RELEASE_DIR}/SnapGlass-update.json"
NOTES_FILE="${RELEASE_DIR}/release-notes.md"

if [ ! -f "$DMG_FILE" ]; then
    echo "❌ DMG not found: $DMG_FILE"
    echo "   Run: bash scripts/build.sh --dmg --sign"
    exit 1
fi

if [ ! -f "${DMG_FILE}.sha256" ]; then
    echo "❌ SHA256 not found: ${DMG_FILE}.sha256"
    exit 1
fi

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TAG" ]; then
    echo "## Changes since $PREV_TAG" > "$NOTES_FILE"
    echo "" >> "$NOTES_FILE"
    git log "$PREV_TAG..HEAD" --oneline --no-merges | sed 's/^/- /' >> "$NOTES_FILE"
else
    echo "## SnapGlass $TAG" > "$NOTES_FILE"
    echo "" >> "$NOTES_FILE"
    git log --oneline --no-merges -20 | sed 's/^/- /' >> "$NOTES_FILE"
fi

# Legacy manifest: 1.4.x clients still read this before they can reach Sparkle.
python3 scripts/generate-update-manifest.py \
    --version "$VERSION" \
    --notes-file "$NOTES_FILE" \
    --checksum-file "${DMG_FILE}.sha256" \
    --output "$UPDATE_MANIFEST"

# Sparkle feed. Fails when the package signature does not verify against the
# public key baked into the app.
bash scripts/make-appcast.sh \
    --version "$VERSION" \
    --build "$BUILD" \
    --dmg "$DMG_FILE" \
    --notes "$NOTES_FILE" \
    --output-dir "$RELEASE_DIR" \
    --download-prefix "https://github.com/blackkcold/snapocr/releases/download/${TAG}/" \
    --key-file "${SIGNING_DIR:-$HOME/.config/snapglass/signing}/sparkle_ed25519.key"

if command -v gh &> /dev/null; then
    echo "📦 Creating GitHub Release $TAG..."
    gh release create "$TAG" \
        --title "$TAG" \
        --notes-file "$NOTES_FILE" \
        "$DMG_FILE" \
        "${DMG_FILE}.sha256" \
        "$UPDATE_MANIFEST" \
        "$APPCAST_FILE"
    echo "✅ Release created: $TAG"
else
    echo "⚠️  gh CLI not installed. Install: brew install gh"
    echo "    Assets are ready in $RELEASE_DIR"
fi
