#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

PACKAGES=(SharedKit CaptureCore OCRCore BarcodeCore AnnotationCore ScrollCore HistoryCore AutomationCore)
ERRORS=0

for pkg in "${PACKAGES[@]}"; do
    echo "=== Testing $pkg ==="
    if swift test --package-path "Packages/$pkg"; then
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
APP_SCHEMES=(EditorInteractionTests WindowLifecycleStateTests BarcodePanelTests)
if command -v xcodebuild >/dev/null 2>&1; then
    if [ ! -d "$PROJECT_ROOT/SnapGlass.xcodeproj" ]; then
        echo "=== Generating Xcode project ==="
        (cd "$PROJECT_ROOT" && xcodegen generate >/dev/null)
    fi
    echo ""
    echo "=== Testing app schemes ==="
    for scheme in "${APP_SCHEMES[@]}"; do
        output="$(cd "$PROJECT_ROOT" && xcodebuild test \
            -project SnapGlass.xcodeproj \
            -scheme "$scheme" \
            -destination 'platform=macOS' 2>&1)" || true
        if echo "$output" | grep -q "Test run with"; then
            summary=$(echo "$output" | grep -m1 -o "Test run with [0-9]* tests.*passed" || true)
            echo "  ✅ $scheme: $summary"
        else
            # A scheme that builds but runs nothing reports "Executed 0 tests";
            # treat that as a failure instead of a silent pass.
            echo "  ❌ $scheme ran no tests"
            echo "$output" | grep -E "error:|Testing failed" | head -5 | sed 's/^/     /'
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "❌ $ERRORS test group(s) failed"
    exit 1
fi

echo ""
echo "✅ All tests passed"
