#!/bin/bash
# Assembles Co-AI Workspace.app from the SwiftPM build product and signs it
# with the App Sandbox entitlements. Kept as a script (not an .xcodeproj) so
# the whole build is reproducible from the command line and in CI.
#
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Co-AI Workspace"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
BIN_NAME="CoAIWorkspace"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product "$BIN_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --product "$BIN_NAME" --show-bin-path)/$BIN_NAME"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Helpers"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Bundled sidecars (surreal arrives in P1.2, searxng in P3.1). Anything placed
# in vendor/helpers is copied in and signed as part of the app.
if [ -d "$ROOT/vendor/helpers" ]; then
  find "$ROOT/vendor/helpers" -maxdepth 1 -type f -perm -u+x -exec cp {} "$APP/Contents/Resources/Helpers/" \;
  echo "    helpers: $(ls -1 "$APP/Contents/Resources/Helpers" 2>/dev/null | tr '\n' ' ')"
else
  echo "    helpers: none yet (vendor/helpers not present)"
fi

# MLX looks for its Metal kernels in the bundles it can see, and the app's
# Resources directory is the one that will be there at runtime. Built
# separately because SwiftPM cannot compile Metal (ARCHITECTURE E.13).
METAL_BUNDLE="$ROOT/vendor/metal/mlx-swift_Cmlx.bundle"
if [ -d "$METAL_BUNDLE" ]; then
  cp -R "$METAL_BUNDLE" "$APP/Contents/Resources/"
  echo "    metal kernels: bundled"
else
  echo "    WARNING: no metal kernels — run scripts/build-metallib.sh, or the"
  echo "             app will fail to load its embedding model"
fi

# §14.3 — App Intents. Siri, Shortcuts and Spotlight find intents by reading
# Contents/Resources/Metadata.appintents, not by looking at the binary: an app
# without this bundle has no intents as far as the system is concerned, however
# many AppIntent types it contains. Xcode runs this processor as a build phase;
# here it is a step, fed by the const values Package.swift asks the compiler to
# emit.
echo "==> App Intents metadata"
PROCESSOR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
CONST_DIR="$(dirname "$BIN_PATH")/CoAIWorkspaceApp.build"
if [ -x "$PROCESSOR" ] && ls "$CONST_DIR"/*.swiftconstvalues >/dev/null 2>&1; then
  WORK="$(mktemp -d)"
  find "$ROOT/Sources/CoAIWorkspaceApp" -name '*.swift' > "$WORK/sources.txt"
  ls "$CONST_DIR"/*.swiftconstvalues > "$WORK/constvals.txt"
  "$PROCESSOR" \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" \
    --module-name CoAIWorkspaceApp \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --target-triple arm64-apple-macosx26.0 \
    --source-file-list "$WORK/sources.txt" \
    --swift-const-vals-list "$WORK/constvals.txt" \
    --force 2>&1 | sed 's/^/    /'
  rm -rf "$WORK"
  # Verified rather than assumed: the processor exits 0 having written nothing
  # if it finds no intents, and "Siri cannot see it" is not a failure anybody
  # discovers from a build log.
  if [ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    COUNT=$(/usr/bin/python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['actions']))" \
      "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then
      echo "    $COUNT intents available to Siri/Shortcuts"
    else
      echo "    ERROR: metadata written but it contains no intents"; exit 1
    fi
  else
    echo "    ERROR: no Metadata.appintents — Shortcuts would not see any intent"; exit 1
  fi
else
  echo "    ERROR: cannot build App Intents metadata (processor or const values missing)"
  exit 1
fi

echo "==> signing with App Sandbox entitlements"
# Sign helpers first — nested code must be signed before the outer bundle.
for helper in "$APP/Contents/Resources/Helpers/"*; do
  [ -e "$helper" ] || continue
  codesign --force --sign - --timestamp=none "$helper" 2>/dev/null || \
    echo "    warning: could not sign $(basename "$helper")"
done
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT/Resources/CoAIWorkspace.entitlements" \
  "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox" \
  && echo "    sandbox entitlement present" \
  || { echo "    ERROR: sandbox entitlement missing"; exit 1; }

echo "==> built: $APP"
