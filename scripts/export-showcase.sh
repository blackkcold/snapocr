#!/bin/bash
set -euo pipefail

# Export the documentation images from the app's DEBUG-only showcase renderer.
#
# The renderer hosts the real SwiftUI views offscreen, writes the PNGs, and
# terminates. It does not capture the screen, touch the user's shelf/editor, or
# depend on Screen Recording permission.
#
# Usage:
#   ./scripts/export-showcase.sh [--build] [output-directory]
#
# Defaults:
#   app:    .build/DerivedData-debug/Build/Products/Debug/SnapGlass.app
#   output: Docs/images/readme/exported
#
# The app target compiles the exporter only in DEBUG; a Release build has no
# SNAPGLASS_SHOWCASE code path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP="${SNAPGLASS_SHOWCASE_APP:-$PROJECT_ROOT/.build/DerivedData-debug/Build/Products/Debug/SnapGlass.app}"
OUTPUT="${SNAPGLASS_SHOWCASE_OUT:-$PROJECT_ROOT/Docs/images/readme/exported}"

BUILD=0
ARGS=()
for argument in "$@"; do
    case "$argument" in
        --build)
            BUILD=1
            ;;
        -h|--help)
            sed -n '1,24p' "$0"
            exit 0
            ;;
        *)
            ARGS+=("$argument")
            ;;
    esac
done

if [ "${#ARGS[@]}" -gt 0 ]; then
    OUTPUT="${ARGS[0]}"
fi

if [ "$BUILD" -eq 1 ]; then
    echo "Building the Debug app for the showcase exporter…"
    xcodebuild \
        -project "$PROJECT_ROOT/SnapGlass.xcodeproj" \
        -scheme SnapGlass \
        -configuration Debug \
        -derivedDataPath "$PROJECT_ROOT/.build/DerivedData-debug" \
        build \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO
fi

EXECUTABLE="$APP/Contents/MacOS/SnapGlass"
if [ ! -x "$EXECUTABLE" ]; then
    echo "Debug app not found at: $APP" >&2
    echo "Run with --build, or set SNAPGLASS_SHOWCASE_APP to a Debug build." >&2
    exit 1
fi

mkdir -p "$OUTPUT"
echo "Exporting showcase images to: $OUTPUT"
SNAPGLASS_SHOWCASE=1 \
SNAPGLASS_SHOWCASE_OUT="$OUTPUT" \
"$EXECUTABLE"

echo "Exported:"
for file in "$OUTPUT"/*.png; do
    [ -e "$file" ] || continue
    printf '  %s\n' "$(basename "$file")"
done
