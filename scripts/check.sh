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
# Which ones. A failing run that does not name the test is a signal nobody can
# act on — and the timing-dependent pair in U12 only fails while the machine is
# busy, which is exactly when this script is running.
echo "$TEST_OUT" | grep '✘ Test "' | sed 's/^/   ✗ /' | head -10
# What the suite could not check. Not failures — a machine with no
# OpenAI-compatible endpoint is the state P5.4 is working towards — but they
# stay in front of a person, because a silent skip reads exactly like a pass.
echo "$TEST_OUT" | grep "^SKIPPED:" | sort -u | sed 's/^/   ⊘ /' 
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

  # Tier 0.5 (P5.1) — the executor contract against a model this process loads
  # itself. Here rather than in `swift test` for the same Metal-kernel reason,
  # and it is the only place the guaranteed floor is checked against real
  # weights. Skips (exit 0) on a machine with no chat model installed.
  step "local chat model (Tier 0.5)"
  if swift run MLXCheck 2>&1 | tail -16; then
    ok "local chat model"
  else
    fail "local chat model"
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
   | grep -v "^Sources/CoAIWorkspaceApp" | grep -v "^Sources/EmbeddingCheck" \
   | grep -v "^Sources/MLXCheck" | grep -q .; then
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

# The app target has no unit tests — it is an executable — so "built but never
# connected" is invisible to `swift test`. It has happened twice: v1's MCP
# client that no session could reach (D6), and ConflictDetector, which passed 7
# tests while nothing in the app ever constructed it, leaving the Conflict
# screen permanently empty. Each capability below must be reachable from the
# wiring, not just from its own tests.
UNWIRED=""
for capability in ConflictDetector RelationExtractor TeamOrchestrator QAReviewer Researcher ContextManager LocalTier ModelInstaller BudgetGovernor EndpointProbe AnalysisStore NotebookKernel NotebookRunner NotebookStore \
                  ProjectService ProjectStore StageGate BriefDrafter WorkspaceStoreCache \
                  WorkPackageStore WorkBreakdown ExceptionStore ToleranceCheck \
                  RegisterStore BaselineStore LessonPublisher \
                  StatTestTool GapDetector AnalysisPlanStore ConnectorStore OfficeWriter \
                  MCPRegistry MCPServerStore Notifier AppIntentsChannel \
                  TemplateStore TemplateParser TemplateFiller PluginRegistry WriteSkillTool \
                  TelegramChannel DiscordChannel LINEChannel ChannelRouter LimitationsBuilder ManifestParser; do
  grep -rqE "$capability[(.]" Sources/CoAIWorkspaceApp --include=*.swift || UNWIRED="$UNWIRED $capability"
done
if [ -n "$UNWIRED" ]; then
  fail "built but never wired into the app:$UNWIRED"
else
  ok "capabilities are reachable from the app, not just from tests"
fi

# ARCHITECTURE §8 / P7.4: no channel may reach a tool. v1's bug B2 was a
# Telegram bridge that ran tools without passing the hook chain, and the fix is
# structural: M4 does not depend on ToolBelt or CoreEngine, so the gateway and
# the tools are not in scope there. Both halves are checked — the import in any
# source file, and the dependency line in Package.swift that would allow it.
CHANNEL_IMPORTS=$(grep -rlE "^import (ToolBelt|CoreEngine|Execution)" Sources/Channels \
  --include='*.swift' 2>/dev/null || true)
# The target's own declaration line only — "Channels" also appears in the app
# target's dependency list, which is where it is *supposed* to be.
CHANNEL_DEPS=$(grep 'name: "Channels", dependencies:' Package.swift \
  | grep -E '"(ToolBelt|CoreEngine|Execution)"' || true)
if [ -n "$CHANNEL_IMPORTS" ] || [ -n "$CHANNEL_DEPS" ]; then
  fail "a channel can reach the tool layer: $CHANNEL_IMPORTS $CHANNEL_DEPS"
else
  ok "no channel can call a tool — the types are not in its module graph"
fi

# ARCHITECTURE §12.5 / P6.5: the "does this statement change anything" check
# belongs to SQLGuard and nowhere else. v1 kept one copy in the notebook and one
# in the DB explorer; they drifted, and the same DELETE warned on one screen and
# ran silently on the other. A second copy would have to name the verbs.
SQL_GUARD_COPIES=$(grep -rlE '"(DROP|TRUNCATE|DELETE|INSERT|ALTER)[ "]' \
  Sources/Analysis Sources/CoAIWorkspaceApp --include='*.swift' \
  | grep -v "SQLGuard.swift" || true)
if [ -n "$SQL_GUARD_COPIES" ]; then
  fail "a second mutating-statement check outside SQLGuard: $SQL_GUARD_COPIES"
else
  ok "the SQL guard exists once, for both the notebook and the DB explorer"
fi

# ARCHITECTURE §5.3 / §M6: a tool the risk table classifies must exist.
#
# This is the sixth instance of one failure — a capability built, tested, and
# reachable from nothing (v1's D6, then ConflictDetector, the P4 team, the MCP
# client, plugins, and then nine tools at once). It was found by reading the
# plan, which is not a method. `RiskScorer.baseline` is the honest place to
# check it: a name is written there because somebody intended a tool, so a name
# with no `AgentTool` behind it is an intention that never landed.
step "tools exist"
UNBUILT=$(/usr/bin/python3 - <<'PY'
import re, os
src = open('Sources/CoreEngine/RiskScorer.swift').read()
baseline = src[src.index('static let baseline'):src.index('/// Names classified above')]
planned = src[src.index('static let notBuiltYet'):src.index('/// Substrings')]
classified = re.findall(r'"([a-z_]+)":', baseline)
declared = set(re.findall(r'"([a-z_]+)":', planned))
implemented = set()
for root, _, files in os.walk('Sources'):
    for name in files:
        if name.endswith('.swift'):
            implemented |= set(re.findall(r'let name\s*=\s*"([a-z_]+)"',
                                          open(os.path.join(root, name)).read()))
print(' '.join(n for n in classified
                if n not in implemented and n not in declared))
PY
)
if [ -n "$UNBUILT" ]; then
  fail "classified in RiskScorer but neither implemented nor declared in notBuiltYet:$UNBUILT"
else
  ok "every classified tool is implemented, or declared as not built yet"
fi

# The declared ones stay in front of a person on every run. A list nobody reads
# is how nine of these went unnoticed until somebody read the plan by hand.
grep -A 6 "static let notBuiltYet" Sources/CoreEngine/RiskScorer.swift \
  | grep -oE '"[a-z_]+": "[^"]+"' | sed 's/^/   ⊘ ยังไม่ได้ทำ: /'

# And every implemented tool is on the tool list the app builds. A tool nobody
# registers is the same gap one step later.
UNREGISTERED=""
for tool in IngestURLTool AnalysisQueryTool AnalysisExecuteTool SaveDocumentTool PullDBTableTool; do
  grep -rq "$tool(" Sources/CoAIWorkspaceApp --include=*.swift || UNREGISTERED="$UNREGISTERED $tool"
done
if [ -n "$UNREGISTERED" ]; then
  fail "built but never registered in the gateway:$UNREGISTERED"
else
  ok "the new tools are registered where a session can reach them"
fi

# Driving the project screen by hand (2026-08-13) found text fields that saved
# on every keystroke: each character wrote to SurrealDB, the reload landed with
# text older than what had been typed since, and a Thai sentence lost roughly
# one character per round-trip. Nothing in `swift test` could see it — the view
# model saved correctly and the store stored correctly; only the two together
# ate the input. The fix is a local buffer committed after a pause, so a write
# inside a Binding setter is the shape to keep out.
KEYSTROKE_WRITES=$(grep -n "Task { await model.update" Sources/CoAIWorkspaceApp/ProjectsView.swift \
  | grep -v "commitCriteria" || true)
if [ -n "$KEYSTROKE_WRITES" ]; then
  # Allowed only from the commit helpers, which run after the debounce.
  if ! grep -q "private func commitDraft" Sources/CoAIWorkspaceApp/ProjectsView.swift; then
    fail "the project screen writes on every keystroke again: $KEYSTROKE_WRITES"
  else
    ok "the project screen buffers edits and commits after a pause"
  fi
else
  ok "the project screen buffers edits and commits after a pause"
fi

# ARCHITECTURE §19.5 / P10.5: the Executive seat is never an agent's. The rule
# is carried by the types — `BoardRole` has no case and no initializer that
# accepts a `Role` — so what this checks is that it stays that way: the moment
# that file mentions `Role`, the compiler stops being the thing enforcing it.
if grep -n "Role" Sources/AgentKit/Accountability.swift \
   | grep -vE "RACIActor|BoardRole|case agent\(Role\)|/// |// " | grep -q .; then
  fail "Accountability.swift refers to Role outside the participant case — the board seat must stay unassignable to an agent"
else
  ok "no agent can hold a board seat, and the types are still what says so"
fi

# ARCHITECTURE §19.6 / P10.4: a leaf reaches `.done` through the evidence check
# or not at all. Same shape as the stage rule above, and for the same reason —
# §19.15 invariant 4 says a finished package has evidence, and a status that can
# be assigned from anywhere is a status that will be.
DONE_WRITERS=$(grep -rn "status = \.done" Sources --include='*.swift' \
  | grep -v "Sources/ProjectKit/WorkBreakdownStructure.swift" || true)
if [ -n "$DONE_WRITERS" ]; then
  fail "a work package is marked done outside WorkBreakdown.complete: $DONE_WRITERS"
else
  ok "a work package is only done with evidence behind it"
fi

# ARCHITECTURE §19.4 / P10.2: a stage changes in one place or it is not a gate.
# `Project.stage` is a `var` because the store has to decode one — so the rule
# that keeps G1–G4 meaningful is that nothing else assigns it. Without this,
# passing a gate becomes a matter of remembering to ask.
STAGE_WRITERS=$(grep -rn "\.stage = " Sources --include='*.swift' \
  | grep -v "Sources/ProjectKit/ProjectService.swift" \
  | grep -v "Sources/AgentKit/Project.swift" || true)
if [ -n "$STAGE_WRITERS" ]; then
  fail "a project's stage is set outside ProjectService.advance/terminate: $STAGE_WRITERS"
else
  ok "a stage only changes by passing its gate"
fi

# ARCHITECTURE §19.4 / P10.2: every tool the risk table classifies must also be
# classified for *effect*, and vice versa. They answer different questions — how
# much damage a call could do, and whether the project's stage allows that kind
# of work at all — and a name in one table but not the other fails quietly: it
# falls to `.mutating` and stops working outside Execution, or it skips the risk
# floor. Quiet is the failure mode this project keeps paying for.
TABLE_DIFF=$(/usr/bin/python3 - <<'TABLES'
import re
risk = open('Sources/CoreEngine/RiskScorer.swift').read()
gate = open('Sources/CoreEngine/StageGate.swift').read()
block = lambda s, start, end: s[s.index(start):s.index(end)]
risky = set(re.findall(r'"([a-z_]+)":', block(risk, 'static let baseline', '/// Names classified above')))
effect = set(re.findall(r'"([a-z_]+)":', block(gate, 'static let effects', '/// What each stage allows')))
print(' '.join(sorted('risk-only:' + n for n in risky - effect) +
               sorted('effect-only:' + n for n in effect - risky)))
TABLES
)
if [ -n "$TABLE_DIFF" ]; then
  fail "RiskScorer and StageGate classify different tools:$TABLE_DIFF"
else
  ok "every tool is classified for both risk and stage effect"
fi

# ARCHITECTURE §14.4 / P8.7: accessibility is a requirement from the start, not
# a pass at the end. v1 had no `aria-*` at all and then had to go back through
# 16 buttons in 8 files — a requirement nothing enforces is a preference, so
# these rules fail the build like the structural ones above.
if /usr/bin/python3 "$ROOT/scripts/accessibility-audit.py" Sources; then
  ok "every action is reachable without a mouse, and says what it does"
else
  fail "accessibility rules (see above)"
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
