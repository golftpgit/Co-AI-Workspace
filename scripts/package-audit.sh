#!/bin/bash
# Is this .app usable on a machine that is not this one? (P9.6)
#
# The Done-when for packaging is "a new machine installs it and it works with
# no manual setup", and the failures that break that are all invisible here —
# on this machine every missing piece is still sitting in the build directory
# where the binary's fallback path can find it. So each check below is a thing
# that works locally and breaks somewhere else:
#
#   1. **Resource bundles.** `Bundle.module` falls back to the absolute path of
#      this machine's build directory. A bundle that was not copied in works
#      here and traps on the first other machine.
#   2. **Non-system dylibs.** A Homebrew library linked at build time is not on
#      a clean machine, and the app fails to launch with a dyld error.
#   3. **The parts that are fetched or built separately** — the database
#      sidecar, the Metal kernels, the App Intents metadata. Each has its own
#      one-time script, which is exactly why each is easy to forget.
#   4. **Signature and sandbox.** An unsigned or unsandboxed build is not the
#      thing that would ship.
#
# Usage: package-audit.sh [path/to/App.app]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Co-AI Workspace.app}"
BIN="$APP/Contents/MacOS/CoAIWorkspace"

FAILED=0
fail() { echo "   ✗ $1"; FAILED=1; }
ok()   { echo "   ✓ $1"; }

if [ ! -d "$APP" ]; then
  echo "   ✗ no app at $APP — run scripts/build-app.sh first"
  exit 1
fi

# 1 — every resource bundle the binary names is where *its own accessor* looks.
#
# "Inside the app" is not the test, and believing it was is what let this audit
# print PACKAGE LOOKS PORTABLE over an app that died on launch (2026-08-18).
# SwiftPM generates two different `Bundle.module` accessors:
#
# `Contents/Resources` is the only place a `.app` may keep them — `codesign`
# refuses loose contents at the bundle root — but it is *not* where SwiftPM's
# generated `Bundle.module` looks: that appends the bundle name to
# `Bundle.main.bundleURL`, which for an app is the `.app` itself. So being in
# `Contents/Resources` is necessary and not sufficient, and the code reaches
# them through `Localisation.bundle(named:)` rather than `Bundle.module`.
MISSING_BUNDLES=""
for name in $(strings -a "$BIN" | grep -oE "[A-Za-z0-9_.-]+\.bundle" | sort -u); do
  # Only the SwiftPM ones: `<package>_<target>.bundle`.
  case "$name" in
    *_*.bundle) ;;
    *) continue ;;
  esac
  [ -d "$APP/Contents/Resources/$name" ] || MISSING_BUNDLES="$MISSING_BUNDLES $name"
done
if [ -n "$MISSING_BUNDLES" ]; then
  fail "resource bundles the binary looks for are not where it looks:$MISSING_BUNDLES"
else
  ok "every resource bundle is where the accessor that loads it looks"
fi

# 2 — nothing links against a library that only exists on this machine.
OUTSIDE=""
while IFS= read -r macho; do
  deps=$(otool -L "$macho" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -vE "^(/usr/lib/|/System/|@rpath/|@executable_path/|@loader_path/)" || true)
  [ -n "$deps" ] && OUTSIDE="$OUTSIDE\n     $(basename "$macho"): $(echo "$deps" | tr '\n' ' ')"
done < <(find "$APP" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
if [ -n "$OUTSIDE" ]; then
  fail "links against libraries outside the system and the bundle:$(printf "$OUTSIDE")"
else
  ok "no dependency on a library that a clean machine would not have"
fi

# 3 — the separately-produced parts.
[ -x "$APP/Contents/Resources/Helpers/surreal" ] \
  && ok "database sidecar bundled" \
  || fail "no Helpers/surreal — run scripts/fetch-helpers.sh (the app cannot start its database)"

[ -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ] \
  && ok "Metal kernels bundled" \
  || fail "no default.metallib — run scripts/build-metallib.sh (the embedding model will not load)"

if [ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
  COUNT=$(/usr/bin/python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['actions']))" \
    "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null || echo 0)
  [ "$COUNT" -gt 0 ] && ok "$COUNT App Intents visible to Siri/Shortcuts" \
    || fail "App Intents metadata contains no intents"
else
  fail "no Metadata.appintents — Shortcuts would see no intents (§14.3)"
fi

# 4 — signed, sandboxed, and honest about who signed it.
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  ok "signature valid, including nested code"
else
  fail "signature invalid — codesign --verify --deep says no"
fi

if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox"; then
  ok "App Sandbox entitlement present"
else
  fail "no app-sandbox entitlement"
fi

# Ad-hoc signing is what a local build gets, and it is *not* what can be
# distributed: Gatekeeper on another machine refuses it. Reported as a note
# rather than a failure, because signing with a Developer ID needs credentials
# that belong to a person, not to a repository.
AUTHORITY=$(codesign -dvvv "$APP" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2-)
if [ -z "$AUTHORITY" ]; then
  echo "   ⊘ signed ad-hoc — fine on this machine, refused by Gatekeeper elsewhere."
  echo "     Distribution needs a Developer ID and notarisation; see README."
else
  ok "signed by: $AUTHORITY"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "PACKAGE LOOKS PORTABLE"
else
  echo "PACKAGE WOULD FAIL ON ANOTHER MACHINE"
fi
exit $FAILED
