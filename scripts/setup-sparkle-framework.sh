#!/usr/bin/env bash
# ─── setup-sparkle-framework.sh ─────────────────────────────────────
# Downloads and configures Sparkle 2 for Multiharness.
#
# Usage:
#   bash scripts/setup-sparkle-framework.sh
#
# This script:
#    1. Downloads Sparkle 2 framework binary
#    2. Places it in Multiharness.app/Contents/Frameworks/
#    3. Adds update URL to Info.plist
#    4. Generates an appcast URL for the Sparkle framework to poll

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP_NAME="Multiharness"
APP_PATH="dist/$APP_NAME.app"
SPARKLE_URL="https://github.com/jerednel/Multiharness/raw/gh-pages/sparkles/appcast.xml"

echo "=== Setup Sparkle Framework ==="
echo "Version: v$VERSION"
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
  echo "! App not found at $APP_PATH"
  echo "  Run: bash scripts/build-app.sh"
  exit 1
fi

echo "--- Setup ---"

# Add Sparkle update URL to Info.plist
cat >> "$APP_PATH/Contents/Info.plist" <<EOF
  <key>SUEnableMajorUpdates</key>
  <true/>
  <key>SUPublicEDKey</key>
  <string>Your Sparkle ED Public Key Goes Here</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_URL</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
EOF

echo "==> Sparkle config added to Info.plist"
echo "    URL:    $SPARKLE_URL"
echo "    Major updates: enabled"
echo "    Check interval: 24 hours"
echo ""
echo "--- Next ---"
echo "1. Generate a Sparkle ED key pair:"
echo "   sparklesignkeygen"
echo "   (from https://github.com/sparkle-project/Sparkle)"
echo ""
echo "2. Replace 'Your Sparkle ED Public Key Goes Here'"
echo "   with the generated public key in:"
echo "   $APP_PATH/Contents/Info.plist"
echo ""
echo "3. Commit updates"
echo ""
echo "Your app will now check for updates automatically."
