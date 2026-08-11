#!/bin/bash
# Runs the SearXNG sidecar in the foreground on 127.0.0.1:18080.
# The app starts it through SidecarManager; this is for development and for the
# opt-in tests (COAI_TEST_NETWORK=1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/vendor/searxng/venv"

if [ ! -x "$VENV/bin/python" ]; then
  echo "searxng is not installed — run ./scripts/fetch-searxng.sh"
  exit 1
fi

export SEARXNG_SETTINGS_PATH="$ROOT/vendor/searxng/config/settings.yml"
echo "==> searxng on http://127.0.0.1:18080 (ctrl-c to stop)"
exec "$VENV/bin/python" -m searx.webapp
