#!/bin/bash
# Hard gate for swift-format.
#
# `swift-format lint` exits 0 even when it reports warnings, so the raw command
# can never be a gate. `--strict` promotes every finding to error severity and
# makes the exit status non-zero, and the diagnostic count is checked on top so
# a future change in that contract fails loudly instead of silently passing.
#
# `.swift-format-budget` must remain 0: the Phase 2 public-API documentation
# cleanup reduced the repository to zero diagnostics, so every diagnostic is a
# failure. A focused run (paths given) is zero-tolerance too, which makes it
# usable for local iteration.
#
# Usage:
#   bash scripts/check-swift-format.sh                           # whole repo, budget
#   bash scripts/check-swift-format.sh App Packages/CaptureCore  # focused, must be 0
#
# Environment:
#   SNAPGLASS_SWIFT_FORMAT_BIN  Formatter binary (default: xcrun's toolchain copy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# The pin is part of the gate: a runner image that ships a different formatter
# must fail here, not fail later with a 6000-line reformat diff.
bash "$SCRIPT_DIR/check-swift-format-version.sh"

FORMATTER="${SNAPGLASS_SWIFT_FORMAT_BIN:-}"
if [[ -z "$FORMATTER" ]]; then
    if FORMATTER="$(xcrun --find swift-format 2>/dev/null)"; then
        :
    elif command -v swift-format >/dev/null 2>&1; then
        FORMATTER="$(command -v swift-format)"
    else
        echo "✗ swift-format not found (xcrun and PATH both failed)." >&2
        exit 1
    fi
fi

TARGETS=("$@")
BUDGET=0
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("$PROJECT_ROOT")
    BUDGET_FILE="$PROJECT_ROOT/.swift-format-budget"
    if [[ ! -f "$BUDGET_FILE" ]]; then
        echo "✗ Missing $BUDGET_FILE" >&2
        exit 1
    fi
    BUDGET="$(grep -vE '^[[:space:]]*(#|$)' "$BUDGET_FILE" | head -1 | tr -d '[:space:]')"
    if [[ ! "$BUDGET" =~ ^[0-9]+$ ]]; then
        echo "✗ $BUDGET_FILE must contain an integer diagnostic budget" >&2
        exit 1
    fi
fi

LOG="$(mktemp -t snapglass-swift-format)"
trap 'rm -f "$LOG"' EXIT

STATUS=0
set +e
"$FORMATTER" lint --strict --recursive "${TARGETS[@]}" \
    --configuration "$PROJECT_ROOT/.swift-format" >"$LOG" 2>&1
STATUS=$?
set -e

# `--strict` reports as `error:`; count both severities so the gate still works
# if the formatter ever regresses to warning-only output.
COUNT="$(grep -cE ': (warning|error): ' "$LOG" || true)"
COUNT="${COUNT:-0}"

if [[ "$COUNT" -gt "$BUDGET" ]]; then
    {
        echo "✗ swift-format: $COUNT diagnostic(s), budget $BUDGET"
        if [[ ${#TARGETS[@]} -eq 1 && "${TARGETS[0]}" == "$PROJECT_ROOT" ]]; then
            echo "  The repository budget must remain 0: $BUDGET_FILE"
        else
            echo "  Focused runs must be clean: fix the diagnostics below."
        fi
        echo ""
        grep -E ': (warning|error): ' "$LOG" | sed -n '1,40p'
        [[ "$COUNT" -gt 40 ]] && echo "  … $((COUNT - 40)) more"
        echo ""
        echo "  Fix in place with:"
        echo "    xcrun swift-format format -i -r . --configuration .swift-format"
        echo "  Then re-run: bash scripts/check-swift-format.sh"
    } >&2
    exit 1
fi

if [[ "$COUNT" -eq 0 && "$STATUS" -ne 0 ]]; then
    # Non-zero with no diagnostics means the formatter itself failed (unparsable
    # file, bad configuration, missing path). Never report that as a pass.
    echo "✗ swift-format exited $STATUS without reporting a diagnostic:" >&2
    sed 's/^/    /' "$LOG" >&2
    exit 1
fi
if [[ "$COUNT" -gt 0 && "$STATUS" -ne 0 && "$STATUS" -ne 1 ]]; then
    echo "✗ swift-format failed while linting (exit $STATUS):" >&2
    sed 's/^/    /' "$LOG" >&2
    exit 1
fi

if [[ "$COUNT" -eq 0 ]]; then
    echo "✅ swift-format: 0 diagnostics"
else
    echo "⚠️  swift-format: $COUNT diagnostic(s), budget $BUDGET — ratchet must not increase"
fi
