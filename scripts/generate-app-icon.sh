#!/usr/bin/env bash
# Regenerate the macOS .icns and the iOS AppIcon.appiconset from a single
# 1024x1024 source PNG (assets/AppIcon-source.png).
#
# Run after replacing the source. Outputs:
#   assets/AppIcon.icns
#   ios/Resources/Assets.xcassets/AppIcon.appiconset/{Contents.json,icon_1024.png}
#
# Both build paths consume these artifacts:
#   - scripts/build-app.sh copies AppIcon.icns into the .app's Resources/
#   - ios/project.yml references the Assets.xcassets via xcodegen

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC="$ROOT/assets/AppIcon-source.png"

if [ ! -f "$SRC" ]; then
  echo "missing source: $SRC" >&2
  exit 1
fi

ICONSET="$ROOT/assets/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

resize() {
  local size="$1" out="$2"
  sips -s format png -z "$size" "$size" "$SRC" --out "$ICONSET/$out" >/dev/null
}

resize 16   icon_16x16.png
resize 32   icon_16x16@2x.png
resize 32   icon_32x32.png
resize 64   icon_32x32@2x.png
resize 128  icon_128x128.png
resize 256  icon_128x128@2x.png
resize 256  icon_256x256.png
resize 512  icon_256x256@2x.png
resize 512  icon_512x512.png
resize 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ROOT/assets/AppIcon.icns"
echo "==> wrote assets/AppIcon.icns"

# iOS asset catalog. iOS 17+ accepts a single 1024x1024 universal image and
# scales it for every slot, which is why we don't generate the legacy 20pt /
# 29pt / 40pt / 60pt sizes.
APPICONSET="$ROOT/ios/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$APPICONSET"
sips -s format png -z 1024 1024 "$SRC" --out "$APPICONSET/icon_1024.png" >/dev/null

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

cat > "$ROOT/ios/Resources/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "==> wrote ios/Resources/Assets.xcassets/AppIcon.appiconset"
