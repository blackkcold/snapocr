#!/bin/bash
# Builds a signed Sparkle appcast for one release.
#
# The appcast, the DMG and the release notes are produced together so the
# enclosure URL, the build number and the signature can be verified before
# anything is published.
#
# Usage:
#   make-appcast.sh --version X.Y.Z --build N --dmg PATH --notes PATH \
#     --output-dir DIR --download-prefix URL --key-file PATH \
#     [--require-signed-feed]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=""
BUILD=""
DMG=""
NOTES=""
OUTPUT_DIR=""
DOWNLOAD_PREFIX=""
KEY_FILE=""
REQUIRE_SIGNED_FEED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --dmg) DMG="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --download-prefix) DOWNLOAD_PREFIX="$2"; shift 2 ;;
        --key-file) KEY_FILE="$2"; shift 2 ;;
        --require-signed-feed) REQUIRE_SIGNED_FEED=true; shift ;;
        -h|--help)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

for required in VERSION BUILD DMG NOTES OUTPUT_DIR DOWNLOAD_PREFIX KEY_FILE; do
    if [[ -z "${!required}" ]]; then
        echo "Missing required option: $required" >&2
        exit 2
    fi
done

for file in "$DMG" "$NOTES" "$KEY_FILE"; do
    [[ -f "$file" ]] || { echo "Missing file: $file" >&2; exit 1; }
done

resolve_generate_appcast() {
    if [[ -n "${GENERATE_APPCAST:-}" && -x "${GENERATE_APPCAST}" ]]; then
        printf '%s\n' "$GENERATE_APPCAST"
        return 0
    fi
    local candidate
    for candidate in \
        ".build/DerivedData-release-universal-arm64/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        ".build/DerivedData-release-universal-x86_64/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        "${SNAPGLASS_DERIVED_DATA:-.build/none}-arm64/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v generate_appcast
}

GENERATE_APPCAST="$(resolve_generate_appcast || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "generate_appcast not found. Build the app once so SPM extracts Sparkle." >&2
    exit 1
fi

case "$DOWNLOAD_PREFIX" in
    */) ;;
    *) DOWNLOAD_PREFIX="$DOWNLOAD_PREFIX/" ;;
esac

STAGING="$OUTPUT_DIR/.appcast-work"
mkdir -p "$STAGING"
DMG_NAME="$(basename "$DMG")"
ditto "$DMG" "$STAGING/$DMG_NAME"
cp "$NOTES" "$STAGING/${DMG_NAME%.*}.md"

echo "▸ Generating signed appcast for v$VERSION (build $BUILD)"
cat "$KEY_FILE" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-versions 1 \
    --embed-release-notes \
    -o "$OUTPUT_DIR/appcast.xml" \
    "$STAGING"

VERIFY_ARGS=(
    "$OUTPUT_DIR/appcast.xml"
    --version "$VERSION"
    --build "$BUILD"
    --asset "$DMG"
    --prefix "$DOWNLOAD_PREFIX"
)
if [[ "$REQUIRE_SIGNED_FEED" == true ]]; then
    VERIFY_ARGS+=(--require-signed-feed)
fi
python3 "$PROJECT_DIR/scripts/verify-appcast.py" "${VERIFY_ARGS[@]}"

echo "✅ appcast: $OUTPUT_DIR/appcast.xml"
