#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=$(cat version.txt | tr -d '[:space:]')
DMG_FILE="release/${VERSION}/SnapGlass-${VERSION}.dmg"

if [ ! -f "$DMG_FILE" ]; then
    echo "❌ DMG not found: $DMG_FILE"
    echo "   Run scripts/build.sh first"
    exit 1
fi

if [ ! -f "${DMG_FILE}.sha256" ]; then
    echo "❌ SHA256 not found: ${DMG_FILE}.sha256"
    exit 1
fi

TEMP_NOTES="/tmp/snapglass-release-notes.md"

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "v$VERSION" ]; then
    echo "## Changes since $PREV_TAG" > "$TEMP_NOTES"
    echo "" >> "$TEMP_NOTES"
    git log "$PREV_TAG..HEAD" --oneline --no-merges | sed 's/^/- /' >> "$TEMP_NOTES"
else
    echo "## SnapGlass v$VERSION" > "$TEMP_NOTES"
    echo "" >> "$TEMP_NOTES"
    git log --oneline --no-merges -20 | sed 's/^/- /' >> "$TEMP_NOTES"
fi

if command -v gh &> /dev/null; then
    echo "📦 Creating GitHub Release v$VERSION..."
    gh release create "v$VERSION" \
        --title "SnapGlass v$VERSION" \
        --notes-file "$TEMP_NOTES" \
        "$DMG_FILE" \
        "${DMG_FILE}.sha256"
    echo "✅ Release created: v$VERSION"
else
    echo "⚠️  gh CLI not installed. Install: brew install gh"
    echo "   Release notes: $TEMP_NOTES"
    echo "   DMG: $DMG_FILE"
fi
