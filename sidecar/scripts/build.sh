#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p dist

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) TARGET="bun-darwin-arm64" ;;
  x86_64) TARGET="bun-darwin-x64" ;;
  *) echo "unsupported arch: $ARCH"; exit 1 ;;
esac

bun build --compile --target="$TARGET" --outfile dist/multiharness-sidecar src/index.ts

# Ad-hoc sign so macOS will run the binary locally. The Mac app's release
# build will replace this with a Developer ID signature during notarization.
# We strip first because Bun's --compile leaves a malformed signature stub
# that codesign --force can't overwrite directly.
codesign --remove-signature dist/multiharness-sidecar 2>/dev/null || true
codesign --force --sign - dist/multiharness-sidecar

ls -lh dist/multiharness-sidecar
