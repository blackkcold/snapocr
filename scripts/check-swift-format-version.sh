#!/bin/bash
# Verifies that the swift-format about to run matches the repository pin.
#
# `.swift-format-version` lists the accepted versions: the first entry is the
# canonical toolchain version, the rest are builds verified to produce identical
# output on this tree. CI runs this before linting so a runner image update
# fails loudly instead of silently reformatting the repository with a different
# formatter.
#
# Override the binary with SNAPGLASS_SWIFT_FORMAT_BIN (for example a Homebrew
# build), otherwise xcrun's toolchain copy is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PIN_FILE="$PROJECT_ROOT/.swift-format-version"

if [[ ! -f "$PIN_FILE" ]]; then
    echo "✗ Missing $PIN_FILE" >&2
    exit 1
fi

FORMATTER="${SNAPGLASS_SWIFT_FORMAT_BIN:-}"
if [[ -z "$FORMATTER" ]]; then
    if FORMATTER="$(xcrun --find swift-format 2>/dev/null)"; then
        :
    elif command -v swift-format >/dev/null 2>&1; then
        FORMATTER="$(command -v swift-format)"
    else
        echo "✗ swift-format not found (xcrun and PATH both failed)." >&2
        echo "  Install Xcode with its command line tools, or set SNAPGLASS_SWIFT_FORMAT_BIN." >&2
        exit 1
    fi
fi

if [[ ! -x "$FORMATTER" ]]; then
    echo "✗ swift-format is not executable: $FORMATTER" >&2
    exit 1
fi

ACCEPTED="$(grep -vE '^[[:space:]]*(#|$)' "$PIN_FILE")"
if [[ -z "$ACCEPTED" ]]; then
    echo "✗ $PIN_FILE lists no versions" >&2
    exit 1
fi
CANONICAL="$(printf '%s\n' "$ACCEPTED" | head -1)"

ACTUAL="$("$FORMATTER" --version 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$ACTUAL" ]]; then
    echo "✗ Cannot read the version of $FORMATTER" >&2
    exit 1
fi

INDEX=0
while IFS= read -r pinned; do
    if [[ "$ACTUAL" == "$pinned" ]]; then
        if [[ "$INDEX" -eq 0 ]]; then
            echo "✅ swift-format $ACTUAL (canonical pin): $FORMATTER"
        else
            echo "✅ swift-format $ACTUAL (verified equivalent to $CANONICAL): $FORMATTER"
        fi
        exit 0
    fi
    INDEX=$((INDEX + 1))
done <<< "$ACCEPTED"

{
    echo "✗ swift-format version mismatch: $ACTUAL"
    echo "  binary:   $FORMATTER"
    echo "  accepted: $(printf '%s\n' "$ACCEPTED" | paste -sd ' ' -) — see .swift-format-version"
    echo ""
    echo "  Update the runner/Xcode so it ships $CANONICAL, or set"
    echo "  SNAPGLASS_SWIFT_FORMAT_BIN to a verified-equivalent build."
    echo "  Do not bump the pin without an intentional repository-wide reformat:"
    echo "    \"$FORMATTER\" format -i -r . --configuration .swift-format"
    echo "    git diff --stat"
} >&2
exit 1
