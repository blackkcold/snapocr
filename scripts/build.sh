#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=""
OUTPUT_DIR=""
OPEN_FINDER=false

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
        -h|--help)
            echo "Usage: $0 [--version X.Y.Z] [--release-dir PATH] [--open]"
            echo ""
            echo "Options:"
            echo "  --version X.Y.Z    指定版本号（默认读取 version.txt）"
            echo "  --release-dir PATH  指定输出目录（默认 release/vX.Y.Z/）"
            echo "  --open              构建后在 Finder 中显示产物"
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
DERIVED_DATA=".build/DerivedData-release"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
OUTPUT_APP="$OUTPUT_DIR/${APP_NAME}.app"

echo "▸ Generating Xcode project"
xcodegen generate

echo "▸ Running Release build for v$VERSION"
xcodebuild -project "SnapGlass.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO

if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build failed: $BUILT_APP not found" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
ditto "$BUILT_APP" "$OUTPUT_APP"

echo "▸ Applying local ad-hoc signature"
codesign --force --deep --sign - "$OUTPUT_APP"
codesign --verify --deep --strict "$OUTPUT_APP"

cat > "$OUTPUT_DIR/BUILD_INFO.json" <<EOF
{
  "version": "$VERSION",
  "buildDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "app": "${APP_NAME}.app",
  "configuration": "Release"
}
EOF

echo ""
echo "✅ App packaged: $OUTPUT_APP"
echo "✅ Build info:  $OUTPUT_DIR/BUILD_INFO.json"

if [[ "$OPEN_FINDER" == true ]]; then
    open -R "$OUTPUT_APP"
fi