#!/bin/bash
# Verifies that the SwiftLint about to run matches the repository pin.
#
# SwiftLint changes rules and thresholds between minor releases, so an unpinned
# `brew install swiftlint` on a runner can turn a green branch red (or hide a new
# violation) without any code change. `.swiftlint-version` is the contract: the
# first entry is canonical, the rest are builds verified to produce an identical
# violation set on this tree.
#
# Override the binary with SNAPGLASS_SWIFTLINT_BIN (for example the pinned
# portable build CI downloads).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PIN_FILE="$PROJECT_ROOT/.swiftlint-version"

if [[ ! -f "$PIN_FILE" ]]; then
    echo "✗ Missing $PIN_FILE" >&2
    exit 1
fi

LINTER="${SNAPGLASS_SWIFTLINT_BIN:-}"
if [[ -z "$LINTER" ]]; then
    for candidate in \
        "$(command -v swiftlint 2>/dev/null || true)" \
        "$HOME/.local/bin/swiftlint" \
        "/opt/homebrew/bin/swiftlint" \
        "/usr/local/bin/swiftlint"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            LINTER="$candidate"
            break
        fi
    done
fi

if [[ -z "$LINTER" ]]; then
    echo "✗ SwiftLint not found." >&2
    echo "  Install the pinned build (see .swiftlint-version) or set SNAPGLASS_SWIFTLINT_BIN." >&2
    exit 1
fi
if [[ ! -x "$LINTER" ]]; then
    echo "✗ SwiftLint is not executable: $LINTER" >&2
    exit 1
fi

ACCEPTED="$(grep -vE '^[[:space:]]*(#|$)' "$PIN_FILE")"
if [[ -z "$ACCEPTED" ]]; then
    echo "✗ $PIN_FILE lists no versions" >&2
    exit 1
fi
CANONICAL="$(printf '%s\n' "$ACCEPTED" | head -1)"

ACTUAL="$("$LINTER" version 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$ACTUAL" ]]; then
    echo "✗ Cannot read the version of $LINTER" >&2
    exit 1
fi

INDEX=0
while IFS= read -r pinned; do
    if [[ "$ACTUAL" == "$pinned" ]]; then
        if [[ "$INDEX" -eq 0 ]]; then
            echo "✅ SwiftLint $ACTUAL (canonical pin): $LINTER"
        else
            echo "✅ SwiftLint $ACTUAL (verified equivalent to $CANONICAL): $LINTER"
        fi
        exit 0
    fi
    INDEX=$((INDEX + 1))
done <<< "$ACCEPTED"

{
    echo "✗ SwiftLint version mismatch: $ACTUAL"
    echo "  binary:   $LINTER"
    echo "  accepted: $(printf '%s\n' "$ACCEPTED" | paste -sd ' ' -) — see .swiftlint-version"
    echo ""
    echo "  Install the pinned portable build:"
    echo "    VERSION=$CANONICAL"
    echo "    mkdir -p \"\$HOME/.local/bin\""
    echo "    curl -fsSL -o /tmp/swiftlint.zip \\"
    echo "      \"https://github.com/realm/SwiftLint/releases/download/\$VERSION/portable_swiftlint.zip\""
    echo "    unzip -oq /tmp/swiftlint.zip -d \"\$HOME/.local/bin\""
} >&2
exit 1
