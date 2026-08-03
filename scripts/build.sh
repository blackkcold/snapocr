#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=""
OUTPUT_DIR=""
OPEN_FINDER=false
CREATE_DMG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --release-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --output-dir)
            # 兼容旧参数名，但不推荐使用
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --open)
            OPEN_FINDER=true
            shift
            ;;
        --dmg)
            CREATE_DMG=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--version X.Y.Z] [--release-dir PATH] [--dmg] [--open]"
            echo ""
            echo "Options:"
            echo "  --version X.Y.Z    指定版本号（默认读取 version.txt）"
            echo "  --release-dir PATH  指定输出目录（默认 release/vX.Y.Z/）"
            echo "  --open              构建后在 Finder 中显示产物"
            echo "  --dmg               同时生成品牌 DMG 与 SHA-256"
            echo ""
            echo "产物统一输出到 release/vX.Y.Z/ 目录。详见 Docs/RELEASE.md。"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(<version.txt)"
    VERSION="${VERSION//[[:space:]]/}"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version: $VERSION" >&2
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="release/v${VERSION}"
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    echo "Output already exists; refusing to overwrite: $OUTPUT_DIR" >&2
    echo "Remove it first or use --release-dir to specify a different directory." >&2
    exit 1
fi

APP_NAME="SnapGlass"
DERIVED_DATA_ROOT="${SNAPGLASS_DERIVED_DATA:-.build/DerivedData-release-universal}"
ARM64_DERIVED_DATA="${DERIVED_DATA_ROOT}-arm64"
X86_64_DERIVED_DATA="${DERIVED_DATA_ROOT}-x86_64"
ARM64_APP="$ARM64_DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
X86_64_APP="$X86_64_DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
OUTPUT_APP="$OUTPUT_DIR/${APP_NAME}.app"

echo "▸ Generating Xcode project"
xcodegen generate

build_architecture() {
    local architecture="$1"
    local derived_data="$2"
    echo "▸ Running Release build for v$VERSION ($architecture)"
    xcodebuild -project "SnapGlass.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -derivedDataPath "$derived_data" \
        -destination "platform=macOS,arch=$architecture" \
        build \
        ARCHS="$architecture" \
        ONLY_ACTIVE_ARCH=YES \
        MARKETING_VERSION="$VERSION" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO
}

build_architecture "arm64" "$ARM64_DERIVED_DATA"
build_architecture "x86_64" "$X86_64_DERIVED_DATA"

if [[ ! -d "$ARM64_APP" || ! -d "$X86_64_APP" ]]; then
    echo "Build failed: architecture-specific app bundle is missing" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
ditto "$ARM64_APP" "$OUTPUT_APP"

OUTPUT_EXECUTABLE="$OUTPUT_APP/Contents/MacOS/$APP_NAME"
UNIVERSAL_EXECUTABLE="$OUTPUT_DIR/${APP_NAME}.universal"
lipo -create \
    "$ARM64_APP/Contents/MacOS/$APP_NAME" \
    "$X86_64_APP/Contents/MacOS/$APP_NAME" \
    -output "$UNIVERSAL_EXECUTABLE"
mv "$UNIVERSAL_EXECUTABLE" "$OUTPUT_EXECUTABLE"
lipo "$OUTPUT_EXECUTABLE" -verify_arch arm64 x86_64

echo "▸ Applying local ad-hoc signature"
codesign --force --deep --sign - "$OUTPUT_APP"
codesign --verify --deep --strict "$OUTPUT_APP"

cat > "$OUTPUT_DIR/BUILD_INFO.json" <<EOF
{
  "version": "$VERSION",
  "buildDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "app": "${APP_NAME}.app",
  "configuration": "Release",
  "architectures": ["arm64", "x86_64"]
}
EOF

echo ""
echo "✅ App packaged: $OUTPUT_APP"
echo "✅ Build info:  $OUTPUT_DIR/BUILD_INFO.json"

if [[ "$CREATE_DMG" == true ]]; then
    bash "$PROJECT_DIR/scripts/package-dmg.sh" \
        --app "$OUTPUT_APP" \
        --version "$VERSION" \
        --output-dir "$OUTPUT_DIR"
fi

if [[ "$OPEN_FINDER" == true ]]; then
    open -R "$OUTPUT_APP"
fi
