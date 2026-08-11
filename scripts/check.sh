#!/bin/bash
# One command for build + test + the project's own structural rules.
# Run this before considering any Task in IMPLEMENTATION_PLAN.md done.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

FAILED=0
step() {
  echo ""
  echo "── $1 ──"
}
fail() { echo "   ✗ $1"; FAILED=1; }
ok()   { echo "   ✓ $1"; }

# MLX's Metal kernels are a per-machine artifact like vendor/helpers/surreal,
# because SwiftPM cannot build them (ARCHITECTURE E.13). Keep the working copy
# beside the test binaries in sync with the one in vendor/, so a plain
# `swift test` finds it.
BUNDLE="mlx-swift_Cmlx.bundle"
if [ -d "vendor/metal/$BUNDLE" ]; then
  for build_dir in .build/debug .build/release; do
    [ -d "$build_dir" ] || continue
    [ -d "$build_dir/$BUNDLE" ] || cp -R "vendor/metal/$BUNDLE" "$build_dir/" 2>/dev/null || true
  done
fi

step "build"
if swift build 2>&1 | tail -3; then ok "build"; else fail "build"; fi

step "tests"
TEST_OUT="$(swift test 2>&1)"
echo "$TEST_OUT" | grep -E "Test run with|error:" | tail -5
echo "$TEST_OUT" | grep -q "Test run with .* passed" && ok "tests" || fail "tests"

# Structural rules from ARCHITECTURE §0.2 — the duplication that made v1 hard
# to maintain is cheap to catch mechanically.
step "embedding model"
if [ -f "vendor/metal/$BUNDLE/Contents/Resources/default.metallib" ]; then
  # The kernels have to sit beside the executable that uses them: MLX resolves
  # them through the main bundle, which for a plain executable is its directory.
  BIN_DIR="$(swift build --show-bin-path 2>/dev/null)"
  if [ -n "$BIN_DIR" ] && [ -d "$BIN_DIR" ]; then
    [ -d "$BIN_DIR/$BUNDLE" ] || cp -R "vendor/metal/$BUNDLE" "$BIN_DIR/" 2>/dev/null || true
  fi
  if swift run EmbeddingCheck 2>&1 | tail -6; then
    ok "embedding model"
  else
    fail "embedding model"
  fi
else
  fail "no metal kernels — run ./scripts/build-metallib.sh"
fi

step "structure"

# Exact declaration only — "enum ScopeColumns" is a different, legitimate type.
DUP_SCOPE=$(grep -rlE "enum Scope[[:space:]]*[:{]" Sources --include=*.swift | wc -l | tr -d ' ')
[ "$DUP_SCOPE" -le 1 ] && ok "Scope declared once" || fail "Scope declared in $DUP_SCOPE files (v1 had 3)"

# The rule is about *library* targets: a library that prints has no way to be
# quiet. Executables are where output is the product — the app writes through
# AppLog, and EmbeddingCheck's whole job is to print what it found.
if grep -rn "print(" Sources --include=*.swift \
   | grep -v "^Sources/CoAIWorkspaceApp" | grep -v "^Sources/EmbeddingCheck" | grep -q .; then
  fail "print() outside the app target — use AppLog/os.Logger"
else
  ok "no stray print() in library targets"
fi

# ARCHITECTURE §5.3: the hook chain must be unbypassable. ToolGateway is the
# only place allowed to invoke a tool; anywhere else would be a second path
# past Critic/Risk/Policy/HITL. v1 had exactly such a path, and it was a bug.
GATE_CALLERS=$(grep -rln "\.call(argumentsJSON" Sources --include=*.swift | grep -v "Sources/CoreEngine/ToolGateway.swift" || true)
if [ -n "$GATE_CALLERS" ]; then
  fail "AgentTool.call invoked outside ToolGateway: $GATE_CALLERS"
else
  ok "tools are only reachable through the hook chain"
fi

if grep -rn ": \[String: Any\]" Sources --include=*.swift | grep -q "Sendable"; then
  fail "[String: Any] on a Sendable type (see ARCHITECTURE App. C)"
else
  ok "no [String: Any] on Sendable types"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "CHECKS FAILED"
fi
exit $FAILED
