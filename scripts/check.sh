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

step "build"
if swift build 2>&1 | tail -3; then ok "build"; else fail "build"; fi

step "tests"
TEST_OUT="$(swift test 2>&1)"
echo "$TEST_OUT" | grep -E "Test run with|error:" | tail -5
echo "$TEST_OUT" | grep -q "Test run with .* passed" && ok "tests" || fail "tests"

# Structural rules from ARCHITECTURE §0.2 — the duplication that made v1 hard
# to maintain is cheap to catch mechanically.
step "structure"

DUP_SCOPE=$(grep -rl "enum Scope" Sources --include=*.swift | wc -l | tr -d ' ')
[ "$DUP_SCOPE" -le 1 ] && ok "Scope declared once" || fail "Scope declared in $DUP_SCOPE files (v1 had 3)"

if grep -rn "print(" Sources --include=*.swift | grep -v "^Sources/CoAIWorkspaceApp" | grep -q .; then
  fail "print() outside the app target — use AppLog/os.Logger"
else
  ok "no stray print() in library targets"
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
