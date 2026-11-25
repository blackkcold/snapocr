#!/bin/bash
# One-time local setup for a SnapGlass checkout.
#
# Idempotent: safe to re-run after pulling. It changes no tracked file, installs
# nothing, and never signs or launches the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "▸ git blame: skip formatting-only commits"
# Local (per-clone) config; keeps `git blame` pointed at the real author.
git config blame.ignoreRevsFile .git-blame-ignore-revs
echo "  blame.ignoreRevsFile = .git-blame-ignore-revs"

echo "▸ formatter version"
# Fails when the toolchain's swift-format drifts from .swift-format-version.
bash scripts/check-swift-format-version.sh

echo "▸ SwiftLint version"
if command -v swiftlint >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/swiftlint" ]]; then
    # Fails when the installed SwiftLint drifts from .swiftlint-version.
    bash scripts/check-swiftlint-version.sh
else
    echo "⚠ SwiftLint not found; install the pinned portable build (see Docs/CONTRIBUTING.md)."
fi

echo "▸ Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "✗ xcodegen not found: brew install xcodegen" >&2
    exit 1
fi
xcodegen generate >/dev/null
echo "  SnapGlass.xcodeproj generated"

if command -v swiftlint >/dev/null 2>&1; then
    echo "▸ SwiftLint $(swiftlint version)"
else
    echo "⚠ SwiftLint not found (see Docs/CONTRIBUTING.md); the Xcode build phase only warns."
fi

echo ""
echo "✅ Local setup complete. Verify with: bash scripts/check-localization.sh && bash scripts/check-swift-format.sh && bash scripts/check-swiftlint-version.sh && swiftlint lint --strict"
