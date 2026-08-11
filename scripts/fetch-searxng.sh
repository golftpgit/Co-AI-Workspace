#!/bin/bash
# Installs SearXNG into vendor/, the same shape as vendor/helpers/surreal:
# per-machine, not in git, one command after a fresh clone.
#
# Why from source and not `pip install searxng`: **the PyPI package named
# `searxng` is not SearXNG.** It is a third-party MCP server that borrowed the
# name (checked 2026-08-11, version 0.0.0.dev0, "MCP server providing
# SearXNG-based web search functionality"). Installing it pulls forty unrelated
# packages and gives you no search engine. The real project ships from git.
#
# Usage: scripts/fetch-searxng.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/vendor/searxng/venv"
CONFIG="$ROOT/vendor/searxng/config/settings.yml"
REPO="git+https://github.com/searxng/searxng.git"

if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import searx" 2>/dev/null; then
  echo "==> searxng already installed"
  "$VENV/bin/python" -c "import searx.version; print('   ', searx.version.VERSION_STRING)" 2>/dev/null || true
  exit 0
fi

echo "==> creating venv"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip setuptools wheel

# Its build backend imports the package, which imports its own runtime, so the
# dependencies have to exist *before* the build — and build isolation has to be
# off or the backend cannot see them.
echo "==> installing dependencies"
"$VENV/bin/pip" install --quiet msgspec
curl -fsSL "https://raw.githubusercontent.com/searxng/searxng/master/requirements.txt" \
  -o "$VENV/../requirements.txt"
"$VENV/bin/pip" install --quiet -r "$VENV/../requirements.txt"

echo "==> installing searxng"
"$VENV/bin/pip" install --quiet --no-build-isolation "$REPO"

if [ ! -f "$CONFIG" ]; then
  echo "==> writing default settings"
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<'YAML'
# JSON is off in SearXNG's defaults, and the API is the only reason we run it.
use_default_settings: true
general:
  debug: false
  instance_name: "Co-AI Workspace"
server:
  bind_address: "127.0.0.1"
  port: 18080
  secret_key: "co-ai-workspace-local-only-not-a-secret"
  limiter: false
  public_instance: false
search:
  formats:
    - html
    - json
  safe_search: 0
YAML
fi

echo "==> verifying"
"$VENV/bin/python" -c "import searx; print('    searx ready')"
echo "    next: ./scripts/run-searxng.sh"
