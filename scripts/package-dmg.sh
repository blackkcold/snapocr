#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH=""
VERSION=""
OUTPUT_DIR=""
TIMESTAMP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_PATH="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --timestamp)
            TIMESTAMP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --app PATH --version X.Y.Z --output-dir PATH [--timestamp YYYYMMDDTHHMMSSZ]"
            echo ""
            echo "  --timestamp  可选。UTC 打包时刻，写进 DMG 文件名做区分（实验打包用）。"
            echo "               缺省时文件名保持正式发布的规范名 SnapGlass-vX.Y.Z.dmg。"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version: $VERSION" >&2
    exit 1
fi

if [[ -n "$TIMESTAMP" && ! "$TIMESTAMP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "Invalid --timestamp (expected UTC YYYYMMDDTHHMMSSZ): $TIMESTAMP" >&2
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "Missing --output-dir" >&2
    exit 1
fi

PYTHON_BIN="${DMGBUILD_PYTHON:-python3}"
if ! "$PYTHON_BIN" -c "import dmgbuild" >/dev/null 2>&1; then
    echo "dmgbuild is unavailable for $PYTHON_BIN" >&2
    echo "Create a virtual environment and install it with: python3 -m pip install dmgbuild" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
DMG_NAME="SnapGlass-v${VERSION}.dmg"
if [[ -n "$TIMESTAMP" ]]; then
    DMG_NAME="SnapGlass-v${VERSION}-${TIMESTAMP}.dmg"
fi
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

if [[ -e "$DMG_PATH" || -e "$CHECKSUM_PATH" ]]; then
    echo "Refusing to overwrite existing DMG output: $DMG_PATH" >&2
    exit 1
fi

BACKGROUND_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snapglass-dmg.XXXXXX")"
BACKGROUND_PATH="$BACKGROUND_DIR/background.png"

echo "▸ Generating Retina DMG background"
xcrun swift "$PROJECT_DIR/scripts/generate-dmg-background.swift" "$BACKGROUND_PATH"

echo "▸ Creating branded DMG"
"$PYTHON_BIN" -m dmgbuild \
    -s "$PROJECT_DIR/scripts/dmg-settings.py" \
    -D "app_path=$APP_PATH" \
    -D "background_path=$BACKGROUND_PATH" \
    -D "icon_path=$APP_PATH/Contents/Resources/AppIcon.icns" \
    "SnapGlass" \
    "$DMG_PATH"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "✅ DMG packaged: $DMG_PATH"
echo "✅ SHA-256:      $CHECKSUM_PATH"
