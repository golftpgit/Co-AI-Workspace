#!/bin/bash
# Downloads the sidecar binaries the app bundles. They are gitignored — a
# 105MB binary does not belong in the repository — so a fresh clone needs this
# once before `scripts/check.sh` can run the persistence suite or the app can
# start its database.
#
# The version is pinned deliberately: ARCHITECTURE App. C.0 documents quirks
# verified against exactly this build, and the schema bootstrap works around
# them. Moving off it is a decision, not an upgrade.
#
# Usage: scripts/fetch-helpers.sh
set -euo pipefail

SURREAL_VERSION="3.2.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT/vendor/helpers"

case "$(uname -m)" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="amd64" ;;
  *) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$HELPERS"

if [ -x "$HELPERS/surreal" ] && "$HELPERS/surreal" version 2>/dev/null | grep -q "$SURREAL_VERSION"; then
  echo "==> surreal $SURREAL_VERSION already present"
else
  URL="https://github.com/surrealdb/surrealdb/releases/download/v${SURREAL_VERSION}/surreal-v${SURREAL_VERSION}.darwin-${ARCH}.tgz"
  echo "==> downloading surreal $SURREAL_VERSION ($ARCH)"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fSL --progress-bar "$URL" -o "$TMP/surreal.tgz"
  tar -xzf "$TMP/surreal.tgz" -C "$TMP"
  mv "$TMP/surreal" "$HELPERS/surreal"
  chmod +x "$HELPERS/surreal"
fi

echo "==> verifying"
"$HELPERS/surreal" version | sed 's/^/    /'
echo "==> helpers ready in vendor/helpers"
echo "    next: ./scripts/check.sh"
