#!/usr/bin/env bash
# One-shot verification of the iOS app build.
#
# Run after any change that touches iOS sources or project.yml. This is what
# `swift build` is for the macOS app — a single command that catches both
# compile errors and Xcode-project-state drift.
#
#   1. Regenerate the .xcodeproj from project.yml so newly added/removed
#      iOS source files appear in the target.
#   2. Resolve Swift package dependencies (the local Multiharness package).
#   3. Build for the iOS Simulator destination.
#
# If you're seeing "Missing package product 'MultiharnessClient'" in Xcode,
# also run this — it forces a clean re-resolve.

set -euo pipefail

cd "$(dirname "$0")/.."
IOS_DIR="$(pwd)/ios"

if [ ! -d "$IOS_DIR" ]; then
  echo "==> No ios/ directory; nothing to build."
  exit 0
fi

cd "$IOS_DIR"

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate >/dev/null

if [ "${MULTIHARNESS_RESET_XCODE_CACHES:-0}" = "1" ]; then
  echo "==> Hard-resetting Xcode caches (DerivedData + workspace state)"
  rm -rf ~/Library/Developer/Xcode/DerivedData/MultiharnessIOS-*
  rm -rf MultiharnessIOS.xcodeproj/project.xcworkspace/xcuserdata
  rm -rf MultiharnessIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  rm -rf MultiharnessIOS.xcodeproj/xcuserdata
fi

echo "==> Resolving Swift package dependencies"
xcodebuild -project MultiharnessIOS.xcodeproj \
    -scheme MultiharnessIOS \
    -destination 'generic/platform=iOS Simulator' \
    -resolvePackageDependencies \
    -quiet

echo "==> Building for iOS Simulator"
xcodebuild -project MultiharnessIOS.xcodeproj \
    -scheme MultiharnessIOS \
    -destination 'generic/platform=iOS Simulator' \
    -quiet \
    build
echo "==> iOS build OK"

# Opt-in: install on a Simulator + launch. Saves having to switch to Xcode
# and click ⌘R after every change.
if [ "${MULTIHARNESS_RUN_SIM:-0}" = "1" ]; then
  SIM_ID="${MULTIHARNESS_SIM_ID:-}"
  if [ -z "$SIM_ID" ]; then
    SIM_ID="$(xcrun simctl list devices available 2>/dev/null \
        | awk -F'[()]' '/iPhone 1[5-9]|iPhone 1[0-9]/ {print $2; exit}')"
  fi
  if [ -z "$SIM_ID" ]; then
    echo "==> No iPhone simulator found; skipping run."
    exit 0
  fi
  echo "==> Booting simulator $SIM_ID (no-op if already booted)"
  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  open -a Simulator
  echo "==> Building for $SIM_ID"
  rm -rf build
  xcodebuild -project MultiharnessIOS.xcodeproj \
      -scheme MultiharnessIOS \
      -destination "id=$SIM_ID" \
      -derivedDataPath build \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      -quiet build
  APP_PATH="$(find build/Build/Products -maxdepth 4 -name 'MultiharnessIOS.app' -type d | head -1)"
  echo "==> Installing $APP_PATH"
  xcrun simctl install "$SIM_ID" "$APP_PATH"
  echo "==> Launching com.multiharness.ios"
  xcrun simctl launch "$SIM_ID" com.multiharness.ios
fi
