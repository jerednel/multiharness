#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Multiharness"
APP_PATH="dist/$APP_NAME.app"
VERSION_FILE="VERSION"
VERSION="0.1.0"

if [ -f "$VERSION_FILE" ]; then
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi

DMG_NAME="$APP_NAME-$VERSION.dmg"
OUT_DIR="dist"
STAGING_DIR="$(mktemp -d)"
STAGING_APP_PATH="$STAGING_DIR/$APP_NAME.app"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

bash scripts/build-app.sh

cp -R "$APP_PATH" "$STAGING_APP_PATH"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$OUT_DIR/$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUT_DIR/$DMG_NAME"

echo "==> Done: $OUT_DIR/$DMG_NAME"
