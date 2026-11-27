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

CURRENT_BUILD="$(tr -d '[:space:]' < build.txt)"
NEW_BUILD=$((CURRENT_BUILD + 1))

# Everything that can fail is checked before anything is written.
#
# The old script rewrote version.txt, build.txt and project.yml first and only then
# tried to insert the CHANGELOG section. When that insert found no anchor it exited
# non-zero with three files already modified, so a failed run left the tree dirty and
# the next run would bump from a half-applied state. Validation is now a separate
# phase from mutation.
NEEDS_CHANGELOG_SECTION=0
if [ -f "CHANGELOG.md" ] && ! grep -q "^## \[$NEW_VERSION\]" CHANGELOG.md; then
    NEEDS_CHANGELOG_SECTION=1
    # The section goes directly under `## [Unreleased]`, where Keep a Changelog puts a
    # new release. The old version inserted before `## [0.1.0]`; this file has no such
    # line, so the insert wrote nothing and every release needed the entry written by
    # hand — silently, because `sed` is happy to match nothing.
    if ! grep -q '^## \[Unreleased\]' CHANGELOG.md; then
        echo "❌ CHANGELOG.md 里没有 '## [Unreleased]' 锚点，无法插入 $NEW_VERSION 段" >&2
        echo "   未改动任何文件。" >&2
        exit 1
    fi
fi

if ! grep -q 'MARKETING_VERSION: "' project.yml; then
    echo "❌ project.yml 里没有 MARKETING_VERSION，拒绝只改一半的版本号" >&2
    echo "   未改动任何文件。" >&2
    exit 1
fi

# ---- mutation phase: nothing below may fail for a reason we could have caught ----

echo "$NEW_VERSION" > version.txt

# Sparkle compares CFBundleVersion, so the build number must increase on every
# release, including re-releases of the same marketing version.
echo "$NEW_BUILD" > build.txt

sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$NEW_VERSION\"/" project.yml

if [ "$NEEDS_CHANGELOG_SECTION" = "1" ]; then
    DATE=$(date +%Y-%m-%d)
    CHANGELOG_TMP="$(mktemp)"
    awk -v version="$NEW_VERSION" -v date="$DATE" '
        BEGIN { inserted = 0 }
        { print }
        !inserted && /^## \[Unreleased\]/ {
            printf "\n## [%s] - %s\n\n### Added\n-\n\n### Fixed\n-\n\n### Changed\n-\n", version, date
            inserted = 1
        }
    ' CHANGELOG.md > "$CHANGELOG_TMP"
    mv "$CHANGELOG_TMP" CHANGELOG.md
fi

git add version.txt build.txt project.yml CHANGELOG.md
git commit -m "chore: bump version to $NEW_VERSION"

# Deliberately no `git tag` here.
#
# `main` only accepts pull requests and merges them with squash, so a tag created on
# the release branch points at a commit squash throws away: it becomes a tag on a
# commit that no longer exists in history, and the pushed tag would not be an ancestor
# of main. A tag is a property of the release, not of the version bump, so it belongs
# after the merge — `Docs/RELEASE.md` documents the annotated form.

echo ""
echo "✅ Version bumped: $CURRENT → $NEW_VERSION (build $CURRENT_BUILD → $NEW_BUILD)"
echo ""
echo "   Next: open the release PR, then after it merges tag the merge commit:"
echo "         git tag -a v$NEW_VERSION -m \"v$NEW_VERSION — 简要描述\""
echo "         git push origin v$NEW_VERSION"
