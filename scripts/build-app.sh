#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUNDLE_NAME="Multiharness"
BUNDLE_ID="com.multiharness.app"

echo "==> Building sidecar binary"
bash sidecar/scripts/build.sh

echo "==> Building Swift package ($CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="dist/$BUNDLE_NAME.app"
CONTENTS="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/$BUNDLE_NAME" "$CONTENTS/MacOS/$BUNDLE_NAME"
cp sidecar/dist/multiharness-sidecar "$CONTENTS/Resources/multiharness-sidecar"
chmod +x "$CONTENTS/MacOS/$BUNDLE_NAME" "$CONTENTS/Resources/multiharness-sidecar"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$BUNDLE_NAME</string>
  <key>CFBundleDisplayName</key><string>$BUNDLE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>$BUNDLE_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing app"
codesign --remove-signature "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
ls -la "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
