#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BINARY="$PROJECT_DIR/.build/library-cli/SnapGlassLibraryCLI"
if [[ "${SNAPGLASS_CLI_REBUILD:-0}" == "1" || ! -x "$BINARY" ]]; then
    xcodegen generate >/dev/null
    xcodebuild \
        -project SnapGlass.xcodeproj \
        -scheme SnapGlassLibraryCLI \
        -configuration Debug \
        -destination 'platform=macOS' \
        build \
        CODE_SIGNING_ALLOWED=NO \
        CONFIGURATION_BUILD_DIR="$PROJECT_DIR/.build/library-cli" >/dev/null
fi

exec "$BINARY" "$@"
