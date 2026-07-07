#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

CURRENT=$(cat version.txt | tr -d '[:space:]')

if [ $# -gt 0 ]; then
    NEW_VERSION="$1"
else
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

echo "▸ Bumping version: $CURRENT → $NEW_VERSION"

echo "$NEW_VERSION" > version.txt

sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$NEW_VERSION\"/" project.yml

if [ -f "CHANGELOG.md" ] && ! grep -q "## \[$NEW_VERSION\]" CHANGELOG.md; then
    DATE=$(date +%Y-%m-%d)
    sed -i '' "/^## \[0\.1\.0\]/i\\
## [$NEW_VERSION] - $DATE\\
\\
### Added\\
-\\
\\
### Fixed\\
-\\
\\
### Changed\\
-\\
\\
" CHANGELOG.md
fi

git add version.txt project.yml CHANGELOG.md
git commit -m "chore: bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo ""
echo "✅ Version bumped: $CURRENT → $NEW_VERSION"
echo "   Tag: v$NEW_VERSION"
echo ""
echo "   Next: scripts/build.sh to create release"
