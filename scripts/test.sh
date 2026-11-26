#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

PACKAGES=(SharedKit CaptureCore OCRCore BarcodeCore AnnotationCore ScrollCore HistoryCore LibraryCore AutomationCore)
ERRORS=0

for pkg in "${PACKAGES[@]}"; do
    echo "=== Testing $pkg ==="
    result=0
    if [ "$pkg" = "CaptureCore" ]; then
        # Audio and writer suites share system media services; CI runs CaptureCore
        # serially, and the local script must match that isolation.
        swift test --package-path "Packages/$pkg" --no-parallel || result=$?
    else
        swift test --package-path "Packages/$pkg" || result=$?
    fi
    if [ "$result" -eq 0 ]; then
        echo "  ✅ $pkg tests passed"
    else
        echo "  ❌ $pkg tests failed"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "❌ $ERRORS package(s) had test failures"
    exit 1
fi

# App-level tests (Swift Testing) live in their own Xcode schemes and were
# previously unreachable from this script.
APP_SCHEMES=(EditorInteractionTests WindowLifecycleStateTests BarcodePanelTests MenuBarCoachPanelTests)
if command -v xcodebuild >/dev/null 2>&1; then
    if [ ! -d "$PROJECT_ROOT/SnapGlass.xcodeproj" ]; then
        echo "=== Generating Xcode project ==="
        (cd "$PROJECT_ROOT" && xcodegen generate >/dev/null)
    fi
    echo ""
    echo "=== Testing app schemes ==="
    for scheme in "${APP_SCHEMES[@]}"; do
        if output="$(cd "$PROJECT_ROOT" && xcodebuild test \
            -project SnapGlass.xcodeproj \
            -scheme "$scheme" \
            -destination 'platform=macOS' 2>&1)"; then
            # A scheme that builds but runs nothing reports "Executed 0 tests";
            # treat that as a failure instead of a silent pass.
            if echo "$output" | grep -q "Test run with"; then
                summary=$(echo "$output" | grep -m1 -o "Test run with [0-9]* tests.*passed" || true)
                echo "  ✅ $scheme: $summary"
            else
                echo "  ❌ $scheme ran no tests"
                echo "$output" | grep -E "error:|Testing failed" | head -5 | sed 's/^/     /'
                ERRORS=$((ERRORS + 1))
            fi
        else
            # Non-zero xcodebuild means at least one test failed or crashed. Never
            # let a "Test run with" summary from an earlier target hide that.
            echo "  ❌ $scheme: xcodebuild failed"
            echo "$output" | grep -E "error:|Failing tests:|TEST FAILED" -A 6 | head -14 | sed 's/^/     /'
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

echo ""
echo "=== Library CLI contract tests ==="
if bash scripts/test-library-cli.sh; then
    echo "  ✅ SnapGlassLibraryCLI"
else
    echo "  ❌ SnapGlassLibraryCLI"
    ERRORS=$((ERRORS + 1))
fi

# Static checks that protect against regressions the compiler cannot see.
# The format budget is 0 after the Phase 2 cleanup, so any diagnostic fails.
echo ""
echo "=== Static checks ==="
if bash scripts/check-swift-format.sh; then
    echo "  ✅ swift-format gate passed"
else
    echo "  ❌ swift-format gate failed"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "❌ $ERRORS test group(s) failed"
    exit 1
fi

echo ""
echo "✅ All tests passed"
