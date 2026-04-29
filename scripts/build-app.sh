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

if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

pick_identity() {
  # 1. Honor explicit override
  if [ -n "${MULTIHARNESS_CODESIGN_CN:-}" ]; then
    echo "$MULTIHARNESS_CODESIGN_CN"
    return
  fi
  local ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null)" || true
  # 2. Apple Development cert is best for local builds — properly trusted,
  #    AMFI happy, runs with full developer permissions.
  local apple_dev
  apple_dev="$(printf '%s\n' "$ids" | awk -F'"' '/Apple Development/ {print $2; exit}')"
  if [ -n "$apple_dev" ]; then echo "$apple_dev"; return; fi
  # 3. Developer ID Application — for distribution but works locally too.
  local devid
  devid="$(printf '%s\n' "$ids" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  if [ -n "$devid" ]; then echo "$devid"; return; fi
  # 4. Self-signed dev cert from setup-codesign.sh
  if printf '%s\n' "$ids" | awk -F'"' '{print $2}' | grep -Fxq "Multiharness Dev"; then
    echo "Multiharness Dev"
    return
  fi
  # 5. Last resort
  echo "-"
}

IDENT="$(pick_identity)"
if [ "$IDENT" = "-" ]; then
  echo "==> No suitable code-signing identity found — falling back to ad-hoc."
  echo "    Run 'bash scripts/setup-codesign.sh' once to create a self-signed"
  echo "    cert, or install Xcode and an Apple Developer account."
else
  echo "==> Signing with '$IDENT'"
fi
codesign --remove-signature "$APP_DIR" 2>/dev/null || true
# Sign the sidecar binary FIRST with JIT entitlements (Bun uses JavaScriptCore's
# JIT — hardened runtime kills the process otherwise).
codesign --force --sign "$IDENT" \
    --options runtime \
    --entitlements "$(cd "$(dirname "$0")" && pwd)/sidecar.entitlements" \
    "$CONTENTS/Resources/multiharness-sidecar"
# Then the outer app — no entitlements needed here, Swift binary doesn't JIT.
codesign --force --deep --sign "$IDENT" --options runtime "$APP_DIR"
# Re-sign the sidecar a second time after --deep to make sure --deep didn't
# strip its entitlements.
codesign --force --sign "$IDENT" \
    --options runtime \
    --entitlements "$(cd "$(dirname "$0")" && pwd)/sidecar.entitlements" \
    "$CONTENTS/Resources/multiharness-sidecar"

echo "==> Done: $APP_DIR"
ls -la "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
