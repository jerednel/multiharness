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

echo "==> Resolving Swift package dependencies (via workspace)"
xcodebuild -workspace MultiharnessIOS.xcworkspace \
    -scheme MultiharnessIOS \
    -destination 'generic/platform=iOS Simulator' \
    -resolvePackageDependencies \
    -quiet

echo "==> Building for iOS Simulator (via workspace)"
xcodebuild -workspace MultiharnessIOS.xcworkspace \
    -scheme MultiharnessIOS \
    -destination 'generic/platform=iOS Simulator' \
    -quiet \
    build
echo "==> iOS build OK"
