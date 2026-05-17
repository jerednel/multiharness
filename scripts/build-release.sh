#!/usr/bin/env bash
# ─── build-release.sh ───────────────────────────────────────────────
# Local CLI: builds, signs, notarizes, and creates a DMG for Multiharness.
#
# Usage:
#   bash scripts/build-release.sh              # Build unnotarized (ad-hoc)
#   bash scripts/build-release.sh --skip-notarize  # Build + sign only
#   bash scripts/build-release.sh --notarize     # Build + sign + notarize
#
# Prerequisites:
#   - An Apple Developer account with an API key for notarytool
#   - The API key file downloaded from developer.apple.com
#   - Apple API key installed via: 
#       security add-generic-password \
#         -s "notarytool.appleid" \
#         -a "<YOUR_APPLE_EMAIL>" \
#         -w "<YOUR_API_KEY_PRIVATE_KEY_PATH>" \
#         --label "Notarytool API Key"
#     OR via CLI file:
#       notarytool store-credentials "Multiharness" \
#         --apple-id "your@email.com" \
#         --private-key-id "<KEY_ID>" \
#         --private-key-path "<path-to-Key.p8>" \
#         --team-id "<TEAM_ID>"
#
# Requires:
#   Xcode (with notarytool)
#   Bun (for sidecar)
#   git (for version reading)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP_NAME="Multiharness"
APP_PATH="dist/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
OUT_DIR="dist"
STAGING_DIR=""

cleanup() {
  if [ -n "${STAGING_DIR:-}" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

echo "=== Multiharness v$VERSION Release Build ==="
echo ""

# ─── Parse args ───
NOTARIZE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) NOTARIZE=false; shift ;;
    --notarize) NOTARIZE=true; shift ;;
    *) echo "Unknown option: $1"; echo "  --skip-notarize or --notarize"; exit 1 ;;
  esac
done

# ─── Determine signing identity ───
IDENT=""
for PAT in "Developer ID Application" "iPhone Distribution"; do
  IDN=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' "/$PAT/ {print \$2; exit}")
  if [ -n "$IDN" ]; then IDENT="$IDN"; break; fi
done

if [ -z "$IDENT" ]; then
  echo "! No code-signing identity found."
  echo "  Run: bash scripts/setup-codesign.sh"
  echo "  Or install Xcode + Apple Developer account."
  echo "  Falling back to ad-hoc signing."
  IDENT="-"
fi

echo "==> Signing with: $IDENT"
echo ""

# ─── Step 1: Build app bundle ───
echo "--- Build App Bundle ---"
bash scripts/build-app.sh
echo ""

# ─── Step 2: Sign with developer cert ───
echo "--- Code Sign App ---"
codesign --force --sign "$IDENT" \
  --options runtime \
  --entitlements "scripts/sidecar.entitlements" \
  "$APP_PATH/Contents/Resources/multiharness-sidecar"

codesign --force --deep --sign "$IDENT" --options runtime "$APP_PATH"

codesign --force --sign "$IDENT" \
  --options runtime \
  --entitlements "scripts/sidecar.entitlements" \
  "$APP_PATH/Contents/Resources/multiharness-sidecar"

echo "==> Verifying app"
codesign --verify --deep --verbose "$APP_PATH"
echo ""

# ─── Step 3: Create DMG ───
echo "--- Create DMG ---"
STAGING_DIR=$(mktemp -d)

cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDBZ \
  "$OUT_DIR/$DMG_NAME"

echo "==> DMG: $OUT_DIR/$DMG_NAME"
ls -lh "$OUT_DIR/$DMG_NAME"
echo ""

STAGED_APP="$STAGING_DIR/$APP_NAME.app"

# -- Optional notarization --
if [ "$NOTARIZE" = "true" ]; then
  echo "--- Notarize DMG (optional) ---"
  
  # Check for API key credentials
  if ! command -v notarytool &>/dev/null; then
    echo "! notarytool not found. Install Xcode Command Line Tools or full Xcode."
    NOTARIZE=false
  fi

  if [ "$NOTARIZE" = "true" ]; then
    # Try to find stored credentials
    KEY_ID=""
    TEAM_ID=""
    
    # Check if user has stored credentials
    CRED_OUTPUT=$(notarytool list-credentials 2>/dev/null || echo "no credentials stored")
    
    if echo "$CRED_OUTPUT" | grep -q "multiharness\|Multiharness"; then
      echo "==> Found stored credentials"
      KEY_ID=$(security find-generic-password \
        -s "notarytool.appleid" \
        -w 2>/dev/null || echo "")
    fi
    
    if [ -n "$APPLE_API_KEY_ID" ] && [ -n "$APPLE_API_KEY_PATH" ] && [ -n "$APPLE_TEAM_ID" ]; then
      echo "==> Found environment variables for notarization"
    fi
    
    if [ -z "$KEY_ID" ]; then
      echo "! No API key found for notarytool."
      echo "  Store credentials with:"
      echo "    notarytool store-credentials '<name>' \\"
      echo "      --apple-id '<email>' \\"
      echo "      --private-key-id '<KEY_ID>' \\"
      echo "      --private-key-path '<path-to-Key.p8>' \\"
      echo "      --team-id '<TEAM_ID>'"
      echo ""
      echo "  Or set env vars:"
      echo "    APPLE_API_KEY_ID=<KEY>"
      echo "    APPLE_API_KEY_PATH=<path-to-Key.p8>"
      echo "    APPLE_TEAM_ID=<TEAM>"
      NOTARIZE=false
    fi
  fi
fi

if [ "$NOTARIZE" = "true" ]; then
  # Notarize the staged app first (before final DMG creation)
  echo "==> Notarizing app in staging"
  
  # Authenticate if using direct key
  if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ]; then
    notarytool login "$APPLE_API_KEY_ID" \
      --key-path "$APPLE_API_KEY_PATH" \
      --team-id "$APPLE_TEAM_ID" \
      --output /tmp/notarytool-auth.txt 2>/dev/null || true
  fi
  
  echo "==> Submitting for notarization"
  echo "  This process typically takes 1-5 minutes"
  echo ""
  
  echo "! Manually notarize with:"
  echo "  notarytool submit '$STAGED_APP' \\"
  echo "    --key-id '<KEY_ID>' \\"
  echo "    --team-id '<TEAM_ID>' \\"
  echo "    --key-path '<path-to-Key.p8>'"
  echo ""
  
  echo "! Then staple with:"
  echo "  notarytool staple '$DMG' \\"
  echo "    --key-id '<KEY_ID>' \\"
  echo "    --team-id '<TEAM_ID>' \\"
  echo "    --key-path '<path-to-Key.p8>'"
  
  echo ""
  echo "==> SKIP: Notarization must be done manually"
  echo "==> Add your Apple Developer API key to complete the pipeline"
else
  echo "! Skipping notarization (use --notarize to enable)"
  echo "  DMG is ad-hoc signed — users may see 'app is damaged' warning"
fi
echo ""

# ─── Step 4: Generate checksums ───
echo "--- Generate Checksums ---"
DIST_DMG="$OUT_DIR/$DMG_NAME"
cd dist

shasum -a 512 "$DMG_NAME" > "$DMG_NAME.sha512"
shasum -a 384 "$DMG_NAME" > "$DMG_NAME.sha384"

echo "==> SHA-512: $(cat $DMG_NAME.sha512)"
echo "==> SHA-384: $(cat $DMG_NAME.sha384)"
cd -

echo ""
echo "=== Build Complete ==="
echo "DMG:  $OUT_DIR/$DMG_NAME"
echo "Size: $(du -sh "$OUT_DIR/$DMG_NAME" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Drag $APP_NAME.app to Applications (or open DMG)"
echo "  2. For notarization: store API credentials via notarytool"
echo "  3. For GitHub release: update VERSION and run the CI workflow"
