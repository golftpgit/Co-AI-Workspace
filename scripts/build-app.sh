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
