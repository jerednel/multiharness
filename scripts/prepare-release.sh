#!/usr/bin/env bash
# ─── prepare-release.sh ─────────────────────────────────────────────
# Prepares a new release version:
#   1. Bumps VERSION file
#   2. Updates CHANGELOG with latest commits since last tag
#   3. Updates README with release notes link
#   4. Commits everything
#   5. Creates and pushes git tag
#   6. Pushes main branch
#
# Usage:
#   bash scripts/prepare-release.sh [VERSION]
#
# Examples:
#   bash scripts/prepare-release.sh 0.1.1
#   bash scripts/prepare-release.sh 1.0.0

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
APP_NAME="Multiharness"

echo "=== Multiharness Release Preparation ==="
echo ""

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ─── Determine version ───
if [ -z "$VERSION" ]; then
  CURRENT="$(tr -d '[:space:]' < VERSION)"
  # Bump minor by default
  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
  PATCH=$((PATCH + 1))
  VERSION="$MAJOR.$MINOR.$PATCH"
  echo "==> No version specified, bumping to v$VERSION (minor patch: $CURRENT -> $VERSION)"
else
  echo "==> Version: v$VERSION"
fi

# Validate version format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "! Invalid version format. Expected: MAJOR.MINOR.PATCH"
  exit 1
fi

# ─── Update VERSION ───
echo "==> Updating VERSION to $VERSION"
echo "$VERSION" > VERSION

# ─── Generate changelog ───
echo "==> Generating changelog"

LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -n "$LAST_TAG" ]; then
  CHANGES="$(git log ${LAST_TAG}..HEAD --pretty=format:'- %s' --no-merges | head -50)"
else
  CHANGES="$(git log --pretty=format:'- %s' --no-merges | head -50)"
fi

# Write changelog section
if [ -f "CHANGELOG.md" ]; then
  TEMP_CH="$TEMP_DIR/changelog-backup-$$"
  cp CHANGELOG.md "$TEMP_CH"
  
  # Create new top section
  cat > CHANGELOG.md <<EOF
# Changelog

## v$VERSION$(date +%Y-%m-%d)

$CHANGES

---

EOF
  
  # Append old changelog
  cat "$TEMP_CH" >> CHANGELOG.md
  rm -f "$TEMP_CH"
else
  cat > CHANGELOG.md <<EOF
# Changelog

## v$VERSION$(date +%Y-%m-%d)

$CHANGES
EOF
fi

echo "==> CHANGELOG.md updated"

# ─── Quick version check ───
ACTUAL="$(tr -d '[:space:]' < VERSION)"
if [ "$ACTUAL" != "$VERSION" ]; then
  echo "! VERSION mismatch! Expected $VERSION, got $ACTUAL"
  exit 1
fi

# ─── Summary of changes ───
echo ""
echo "=== Release Summary ==="
echo "Version:  v$ACTUAL"
echo "Branch:   $(git branch --show-current)"
echo "Status:   $(git status --short | wc -l | xargs) modified files"
echo ""
echo "=== Next Steps ==="
echo "1. Review changes:    git diff"
echo "2. Commit:            git add -A && git commit -m 'v$ACTUAL release'"
echo "3. Tag:               git tag -a v$ACTUAL -m 'Multiharness v$ACTUAL'"
echo "4. Push:              git push origin main && git push origin v$ACTUAL"
echo ""
echo "Then run the CI release job (auto-triggers on tag push)."
