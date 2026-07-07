#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  VERSION="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--version X.Y.Z]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$VERSION" ]; then
    VERSION=$(cat version.txt | tr -d '[:space:]')
fi

APP_NAME="SnapGlass"
BUNDLE_ID="com.snapglass.app"
RELEASE_DIR="release/${VERSION}"

echo "╔══════════════════════════════════════════════════╗"
echo "║  SnapGlass Build                                 ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Version:  $VERSION"
echo "║  Config:   Release"
echo "║  Sign:     ${SNAPGLASS_SIGN_IDENTITY:-ad-hoc}"
echo "╚══════════════════════════════════════════════════╝"
echo ""

echo "▸ Generating Xcode project..."
if command -v xcodegen &>/dev/null; then
    xcodegen generate
elif [ ! -f "SnapGlass.xcodeproj/project.pbxproj" ]; then
    echo "❌ xcodegen not found and no existing .xcodeproj"
    echo "   Install: brew install xcodegen"
    exit 1
else
    echo "  Using existing SnapGlass.xcodeproj"
fi

echo "▸ Building SnapGlass (Release)..."
ARCHIVE_DIR=".build/archive"
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"

xcodebuild -project SnapGlass.xcodeproj \
    -scheme SnapGlass \
    -configuration Release \
    -archivePath "$ARCHIVE_DIR/SnapGlass.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    2>&1 | tail -5

APP_PATH="$ARCHIVE_DIR/SnapGlass.xcarchive/Products/Applications/SnapGlass.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed: SnapGlass.app not found"
    exit 1
fi

echo "  ✅ Build complete"

echo "▸ Packaging..."
mkdir -p "$RELEASE_DIR"
rm -rf "$RELEASE_DIR/${APP_NAME}.app"
cp -R "$APP_PATH" "$RELEASE_DIR/${APP_NAME}.app"

echo "▸ Signing..."
if [ -n "${SNAPGLASS_SIGN_IDENTITY:-}" ]; then
    echo "   Identity: ${SNAPGLASS_SIGN_IDENTITY}"
    ENTITLEMENTS_PATH="App/SnapGlass/SnapGlass.entitlements"
    if [ -f "$ENTITLEMENTS_PATH" ]; then
        codesign --force --deep --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS_PATH" \
            --sign "$SNAPGLASS_SIGN_IDENTITY" \
            "$RELEASE_DIR/${APP_NAME}.app" 2>/dev/null || \
        codesign --force --deep --options runtime \
            --entitlements "$ENTITLEMENTS_PATH" \
            --sign "$SNAPGLASS_SIGN_IDENTITY" \
            "$RELEASE_DIR/${APP_NAME}.app"
    else
        codesign --force --deep --options runtime --timestamp \
            --sign "$SNAPGLASS_SIGN_IDENTITY" \
            "$RELEASE_DIR/${APP_NAME}.app" 2>/dev/null || \
        codesign --force --deep --options runtime \
            --sign "$SNAPGLASS_SIGN_IDENTITY" \
            "$RELEASE_DIR/${APP_NAME}.app"
    fi
    echo "   Signed with runtime + timestamp"
else
    echo "   ⚠️  SNAPGLASS_SIGN_IDENTITY not set — using ad-hoc signing"
    codesign --force --deep --sign - "$RELEASE_DIR/${APP_NAME}.app"
fi

echo "▸ Creating DMG..."
DMG_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}.dmg"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$RELEASE_DIR/${APP_NAME}.app" \
    -ov -format UDZO \
    "$DMG_PATH" 2>/dev/null

echo "▸ Generating SHA256..."
shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "${DMG_PATH}.sha256"

cat > "$RELEASE_DIR/BUILD_INFO.json" <<EOF
{
  "version": "$VERSION",
  "configuration": "Release",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "signed": $([ -n "${SNAPGLASS_SIGN_IDENTITY:-}" ] && echo true || echo false)
}
EOF

echo "▸ Updating latest symlink..."
rm -f release/latest
ln -sfn "$VERSION" release/latest

echo "▸ Updating versions.json..."
VERSIONS_FILE="release/versions.json"
DATE=$(date +%Y-%m-%d)

if [ -f "$VERSIONS_FILE" ]; then
    python3 -c "
import json, sys
with open('$VERSIONS_FILE', 'r') as f:
    versions = json.load(f)
versions = [v for v in versions if v['version'] != '$VERSION']
versions.insert(0, {'version': '$VERSION', 'date': '$DATE', 'file': '${APP_NAME}-${VERSION}.dmg'})
with open('$VERSIONS_FILE', 'w') as f:
    json.dump(versions, f, indent=4)
" 2>/dev/null || echo '[{"version": "'$VERSION'", "date": "'$DATE'", "file": "'${APP_NAME}-${VERSION}.dmg'"}]' > "$VERSIONS_FILE"
else
    echo '[{"version": "'$VERSION'", "date": "'$DATE'", "file": "'${APP_NAME}-${VERSION}.dmg'"}]' > "$VERSIONS_FILE"
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅ Build Complete                                ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║  App:      $RELEASE_DIR/${APP_NAME}.app"
echo "║  DMG:      $DMG_PATH"
echo "║  SHA256:   ${DMG_PATH}.sha256"
echo "║  Latest:   release/latest → $VERSION"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
ls -lh "$DMG_PATH"
