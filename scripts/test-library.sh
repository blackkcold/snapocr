#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== LibraryCore unit tests ==="
swift test --package-path Packages/LibraryCore

echo ""
echo "=== Real-media merge export test ==="
swift test --package-path Packages/CaptureCore --filter RecordingMergeExportTests

echo ""
echo "=== Library CLI contract tests ==="
bash scripts/test-library-cli.sh

echo ""
echo "=== Localization ==="
bash scripts/check-localization.sh

echo ""
echo "✅ Library automated checks passed"
