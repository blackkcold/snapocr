#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

PACKAGES=(SharedKit CaptureCore OCRCore BarcodeCore AnnotationCore ScrollCore HistoryCore)
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

echo ""
echo "✅ All tests passed"
