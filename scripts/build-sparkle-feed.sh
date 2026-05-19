#!/usr/bin/env bash
# ─── build-sparkle-feed.sh ───────────────────────────────────────────
# Generates a Sparkle 2 appcast file and checksums for auto-updates.
#
# Usage:
#   bash scripts/build-sparkle-feed.sh [VERSION]
#
# Outputs:
#   sparkles/     — Sparkle feed directory with appcast.xml
#   Sparkle       — Sparkle framework binary (for bundling in the Mac app)
#
# After generating, commit the appcast to your GitHub Pages branch:
#   git add sparkles/
#   git commit -m "Update Sparkle feed for v${VERSION}"
#   git push origin main

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
APP_NAME="Multiharness"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
FEED_DIR="${FEED_DIR:-.github/sparkles}"
APPCAST_XML="$FEED_DIR/appcast.xml"
APP_VERSION="$VERSION"

echo "=== Sparkle 2 Feed Generator ==="
echo "Version: v$APP_VERSION"
echo ""

# ─── Get full changelog ───
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
  CHANGES="$(git log ${LAST_TAG}..HEAD --pretty=format:'%s' --no-merges | head -50)"
else
  CHANGES="$(git log --pretty=format:'%s' --no-merges | head -50)"
fi

# ─── Generate checksums ───
echo "--- Generate Checksums ---"
DISTD="dist"
if [ -f "$DISTD/$DMG_NAME" ]; then
  SHA384=$(cd "$DISTD" && shasum -a 384 "$DMG_NAME" | cut -d' ' -f1)
  SHA512=$(cd "$DISTD" && shasum -a 512 "$DMG_NAME" | cut -d' ' -f1)
  SIZE=$(stat -f%z "$DISTD/$DMG_NAME" 2>/dev/null || stat -f%z "$DISTD/$DMG_NAME")
  echo "SHA-384: $SHA384"
  echo "SHA-512: $SHA512"
  echo "Size:    $SIZE bytes"
else
  echo "! DMG $DMG_NAME not found in dist/"
  echo "  Run: bash scripts/build-release.sh"
  exit 1
fi
echo ""

# ─── Generate appcast.xml ───
echo "--- Generate appcast.xml ---"
echo "==> Writing to $APPCAST_XML"
echo ""

mkdir -p "$FEED_DIR"

cat > "$APPCAST_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkle-project.org/schema/s" xmlns:dc="http://purl.org/dc/terms/">
<channel>
<title>$APP_NAME Sparkle Feed</title>
<link>https://github.com/jerednel/Multiharness/releases</link>
<description>Official updates for $APP_NAME</description>
<language>en</language>
<item>
  <title>v$APP_VERSION</title>
  <pubDate>$(date -R)</pubDate>
  <link>https://github.com/jerednel/Multiharness/releases</link>
  <enclosure url="https://github.com/jerednel/Multiharness/releases/download/v${APP_VERSION}/$DMG_NAME"
             sparkle:version="1"
             sparkle:shortVersionString="${APP_VERSION}"
             sparkle:minimumSystemVersion="14.0"
             type="data"
             length="$SIZE"
             sparkle:edSignature="TODO-SIGN-THIS"
  />
  <sparkle:releaseNotesLink>
    <![CDATA[
      <h2>$APP_NAME v$APP_VERSION</h2>
      <ul>
$(echo "$CHANGES" | sed 's/^/        <li>/;s/$/<\/li>/')
      </ul>
    ]]>
  </sparkle:releaseNotesLink>
  <description>See the changelog for full details.</description>
</item>
</channel>
</rss>
EOF

echo "=== Done ==="
echo "Feed:  $APPCAST_XML"
echo "DMG:   $DISTD/$DMG_NAME"
echo ""
echo "Next steps:"
echo "  1. Sign the appcast using a Sparkle edPrivateKey"
echo "     See: https://sparkle-project.org/documentation/ed-signing/"
echo "  2. Commit appcast to GitHub Pages branch"
echo "  3. Update Sparkle URL in the Mac app bundle"
echo "  4. Push the tag to trigger CI release build"
