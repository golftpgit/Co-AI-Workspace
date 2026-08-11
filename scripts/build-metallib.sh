#!/bin/bash
# Builds MLX's Metal kernels, which SwiftPM cannot (mlx-swift says so itself:
# "SwiftPM (command line) cannot build the Metal shaders so the ultimate build
# has to be done via Xcode"). Everything else in this project stays SwiftPM.
#
# The result is a per-machine artifact, the same shape as vendor/helpers/surreal:
# not in git, built once, and checked for by scripts/check.sh. Run it after a
# fresh clone and after changing the mlx-swift version — nothing else.
#
# Requires the Metal Toolchain, which Xcode 26 ships as a separate download:
#   xcodebuild -downloadComponent MetalToolchain
#
# Usage: scripts/build-metallib.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUNDLE_NAME="mlx-swift_Cmlx.bundle"
VENDOR="$ROOT/vendor/metal"
DERIVED="$ROOT/.build/metal-derived"

if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "Status: installed"; then
  echo "==> Metal Toolchain is not installed."
  echo "    Without it MLX fails at runtime with 'Failed to load the default metallib'."
  echo "    Install it once with:"
  echo ""
  echo "        xcodebuild -downloadComponent MetalToolchain"
  echo ""
  exit 1
fi

echo "==> building Metal kernels ($CONFIG) — several minutes the first time"
# Any scheme that pulls in mlx-swift builds the kernels; the app is the one
# that will ship them. Plugin validation is interactive-only and would stall
# a scripted build.
xcodebuild \
  -scheme CoAIWorkspace \
  -configuration "$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build 2>&1 | grep -E "error:|warning: .*metal|BUILD (SUCCEEDED|FAILED)" || true

BUILT="$(find "$DERIVED/Build/Products" -name "$BUNDLE_NAME" -maxdepth 2 2>/dev/null | head -1)"
if [ -z "$BUILT" ]; then
  echo "   ✗ no $BUNDLE_NAME was produced — see the xcodebuild output above"
  exit 1
fi

echo "==> installing"
mkdir -p "$VENDOR"
rm -rf "${VENDOR:?}/$BUNDLE_NAME"
cp -R "$BUILT" "$VENDOR/"

# SwiftPM binaries (tests, `swift run`) look for the bundle beside the
# executable, so put a working copy there too. check.sh refreshes this from
# vendor/ when it is missing, which is what makes a plain `swift test` work.
for build_dir in "$ROOT/.build/debug" "$ROOT/.build/release"; do
  [ -d "$build_dir" ] || continue
  rm -rf "${build_dir:?}/$BUNDLE_NAME"
  cp -R "$VENDOR/$BUNDLE_NAME" "$build_dir/"
done

METALLIB="$VENDOR/$BUNDLE_NAME/Contents/Resources/default.metallib"
if [ ! -f "$METALLIB" ]; then
  echo "   ✗ bundle has no default.metallib inside it"
  exit 1
fi

echo "==> metal kernels ready"
echo "    $(du -h "$METALLIB" | cut -f1)  $METALLIB"
echo "    next: ./scripts/check.sh"
