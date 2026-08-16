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
BUILD_OUT="$(swift build 2>&1)"
echo "$BUILD_OUT" | tail -3
echo "$BUILD_OUT" | grep -q "error:" && fail "build" || ok "build"

# One warning class fails the build, because its symptom is a user seeing
# `Optional("P-7QK2")` on screen. It has now happened twice — once in the
# analysis status line, once on the transcript row, where it was driven and
# seen. The compiler said so both times and the message was lost in a build log
# nobody greps for anything but "error:".
DEBUG_DESCRIPTION=$(echo "$BUILD_OUT" \
  | grep "string interpolation produces a debug description" | sort -u)
if [ -n "$DEBUG_DESCRIPTION" ]; then
  echo "$DEBUG_DESCRIPTION" | sed 's/^/   /' | head -5
  fail "an optional is interpolated into a string — it renders as Optional(…) to a person"
else
  ok "no optional is interpolated straight into text"
fi

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
# AppLog, and EmbeddingCheck, MLXCheck, TierOneCheck and UIResponsivenessCheck
# exist to print what they
# measured. The list is spelled out rather than derived from Package.swift: an
# executable added here is a deliberate act, and having to name it is the point
# at which somebody asks whether the printing belongs in a library.
#
# Anchored on a word boundary since P11.1's gate work: `InstrumentFootprint(`
# ends in the same six letters, and so would any `Blueprint(` or `Sprint(`. A
# structural rule that fails on a name is a rule people learn to route around.
#
# Comment lines are skipped for the same reason, found the same way: P11.9's
# note explaining why a figure must not be scraped out of a `print()` tripped
# the rule about calling one. A rule that fires on prose teaches people not to
# write the prose.
if grep -rnE "(^|[^A-Za-z0-9_.])print\(" Sources --include=*.swift \
   | grep -vE ":[0-9]+:[[:space:]]*(///?|\*)" \
   | grep -v "^Sources/CoAIWorkspaceApp" | grep -v "^Sources/EmbeddingCheck" \
   | grep -v "^Sources/MLXCheck" | grep -v "^Sources/TierOneCheck" \
   | grep -v "^Sources/UIResponsivenessCheck" | grep -q .; then
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

# ARCHITECTURE §5.3 / §11.2, risk R14: the app must install a policy gate.
#
# `HookChain`'s `policyGate` defaults to `NoPolicyGate`, which is correct for a
# test that is not about policy and catastrophic for the app: from P2.6 until
# 2026-08-15 the app built `HookChain(stageGate:)` and therefore ran with no
# policy at all, while eleven tests proved the gate worked. Nothing failed,
# because the tests construct their own chain. This checks the wiring itself.
POLICY_WIRING=$(grep -A3 "ToolGateway(chain: HookChain(" Sources/CoAIWorkspaceApp/Engine.swift | grep -c "policyGate:" || true)
if [ "$POLICY_WIRING" -lt 1 ]; then
  fail "the app builds its hook chain without a policyGate — policy rules would stop nothing (R14)"
else
  ok "the app installs a policy gate, so the policy scope can actually stop a call"
fi

# The app target has no unit tests — it is an executable — so "built but never
# connected" is invisible to `swift test`. It has happened twice: v1's MCP
# client that no session could reach (D6), and ConflictDetector, which passed 7
# tests while nothing in the app ever constructed it, leaving the Conflict
# screen permanently empty. Each capability below must be reachable from the
# wiring, not just from its own tests.
#
# P11.3's arithmetic (EFA, ConstructFit, ω) is reached *through* `ScaleReport`,
# which is on the list and whose own tests assert that a real factor solution and
# a real construct-fit comparison come back from it. Naming the inner types here
# too would only check that the screen mentions them.
UNWIRED=""
for capability in ConflictDetector RelationExtractor TeamOrchestrator QAReviewer Researcher ContextManager LocalTier ModelInstaller BudgetGovernor EndpointProbe AnalysisStore NotebookKernel NotebookRunner NotebookStore \
                  ProjectService ProjectStore StageGate BriefDrafter WorkspaceStoreCache \
                  WorkPackageStore WorkBreakdown ExceptionStore ToleranceCheck \
                  RegisterStore BaselineStore LessonPublisher \
                  StatTestTool GapDetector AnalysisPlanStore ConnectorStore OfficeWriter \
                  MCPRegistry MCPServerStore Notifier AppIntentsChannel \
                  TemplateStore TemplateParser TemplateFiller PluginRegistry WriteSkillTool \
                  TelegramChannel DiscordChannel LINEChannel ChannelRouter LimitationsBuilder ManifestParser \
                  ScaleReport ScoredResponses InstrumentDisposal ProjectTypeGateReader \
                  CodebookStore CodingAnalysis CellRunStore ManuscriptBuilder \
                  KnowledgeView ViewWidenings WidenViewTool InstallPackageTool \
                  RoleMemory ToolProficiency EntityGraph; do
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

# ARCHITECTURE §20.6 / P11: M15 designs instruments and must not be able to serve
# one. The dependency list *is* the invariant — an instrument that could open a
# socket could collect data before passing its gate, and the gate is the strongest
# one in a research project because fieldwork cannot be redone.
INSTRUMENT_NETWORK=$(grep -rlE "^import (Network|WebKit|NIO|Vapor)|URLSession|NWListener" Sources/Instruments 2>/dev/null || true)
INSTRUMENT_DEPS=$(/usr/bin/python3 - <<'DEPS'
import re
manifest = open('Package.swift').read()
block = manifest[manifest.index('.target(name: "Instruments"'):]
block = block[:block.index('),') + 1]
# `StatKit` joined the list in P11.3. It is arithmetic with no dependencies of
# its own — distribution tails and an eigen-decomposition — so it is not a way
# to reach a socket, which is the thing this rule is about.
allowed = {"AgentKit", "Knowledge", "Observability", "StatKit"}
found = set(re.findall('"([A-Za-z]+)"', block)) - {"Instruments"}
print(' '.join(sorted(found - allowed)))
DEPS
)
if [ -n "$INSTRUMENT_NETWORK" ] || [ -n "$INSTRUMENT_DEPS" ]; then
  fail "M15 Instruments reached for the network:$INSTRUMENT_NETWORK $INSTRUMENT_DEPS"
else
  ok "M15 designs instruments and cannot serve one"
fi

# ARCHITECTURE §20.2 / P11.1: a project type is a file read by the parser that
# already reads agents and skills. Two readers would drift, and the first thing to
# drift would be the field that decides what a project starts with. The rule is
# mechanical: only `Manifest.swift` may take frontmatter apart, so anything else
# that goes looking for the `---` fence is a second parser being born.
FENCE_READERS=$(grep -rln '"---"' Sources/ --include=*.swift 2>/dev/null | grep -v "Sources/Roster/Manifest.swift" || true)
# And every type the app ships must name a WBS template that exists, or a project
# starts with an empty plan and no complaint.
TEMPLATE_GAP=$(/usr/bin/python3 - <<'TPL'
import re, glob, os
known = set(re.findall(r'"([a-z0-9-]+)"',
    re.search(r'names = \[(.*?)\]',
              open('Sources/Roster/WBSTemplate.swift').read(), re.S).group(1)))
missing = []
for path in sorted(glob.glob('Resources/project-types/*.md')):
    text = open(path, encoding='utf-8').read()
    found = re.search(r'^wbs_template:\s*(\S+)', text, re.M)
    if found and found.group(1) not in known:
        missing.append(os.path.basename(path) + ' -> ' + found.group(1))
print(' '.join(missing))
TPL
)
if [ -n "$FENCE_READERS" ] || [ -n "$TEMPLATE_GAP" ]; then
  fail "a second manifest parser or a missing WBS template:$FENCE_READERS $TEMPLATE_GAP"
else
  ok "project types are files, read by the one manifest parser"
fi

# ARCHITECTURE §19.17 invariant 1 / P11.6b: M16 writes to SQLite and nowhere
# else. DuckDB is an OLAP engine built around a single writer; pointing a web
# server's INSERTs at it does not fail on this machine, it fails on the day
# twenty people are answering — which is the one day fieldwork cannot be redone.
# The dependency list is what makes that a fact rather than an intention.
FIELD_DUCK=$(grep -rlE "^import (Analysis|DuckDB)" Sources/FieldServer 2>/dev/null || true)
FIELD_DEPS=$(/usr/bin/python3 - <<'DEPS'
import re
manifest = open('Package.swift').read()
block = manifest[manifest.index('.target(name: "FieldServer"'):]
block = block[:block.index('])') + 1]
allowed = {"AgentKit", "Observability", "Instruments", "OLTP"}
found = set(re.findall('"([A-Za-z]+)"', block)) - {"FieldServer"}
print(' '.join(sorted(found - allowed)))
DEPS
)
# Invariant 2: no UPDATE or DELETE on a raw answer, anywhere. Changing a value is
# a correction record — research data that can be quietly overwritten is research
# data nobody can prove was not overwritten.
ANSWER_MUTATION=$(grep -rniE "(UPDATE|DELETE) +(FROM +)?(answer|submission)\b" Sources/OLTP Sources/FieldServer 2>/dev/null || true)
# The pull is one-directional: Analysis reads OLTP, OLTP knows nothing about
# DuckDB. If that edge ever reversed, M16 would have a path to the analytical
# store through the module it writes to.
OLTP_ANALYSIS=$(grep -rlE "^import (Analysis|DuckDB)" Sources/OLTP 2>/dev/null || true)
FIELD_DUCK="$FIELD_DUCK $OLTP_ANALYSIS"
FIELD_DUCK=$(echo "$FIELD_DUCK" | xargs)
if [ -n "$FIELD_DUCK" ] || [ -n "$FIELD_DEPS" ] || [ -n "$ANSWER_MUTATION" ]; then
  fail "M16 reached past SQLite:$FIELD_DUCK $FIELD_DEPS $ANSWER_MUTATION"
else
  ok "M16 writes answers to SQLite only, and never over one already given"
fi

# ARCHITECTURE §12.3 / §20.4, P11.3: the distribution tails and the eigen call
# exist once. They used to live inside `Statistics`, which was fine while M8 was
# the only caller; M15 needing a chi-square tail is what would have produced a
# second copy — and two continued fractions agree for years and then disagree at
# the fourth decimal in the one table somebody publishes. Same shape as the SQL
# guard rule above, and the same reason.
MATH_COPIES=$(grep -rln "betaContinuedFraction\|regularizedIncompleteGamma" Sources --include=*.swift \
  | grep -v "Sources/StatKit/Distributions.swift" | grep -v "Sources/Analysis/Statistics.swift" || true)
# `Statistics` may name them because it forwards, so the names alone say
# nothing there. What a reimplementation needs is the innards — a log-gamma, an
# erfc, or Lentz's underflow guard — and none of those has any other business in
# that file.
if grep -qE "lgamma\(|erfc\(|1e-300" Sources/Analysis/Statistics.swift; then
  MATH_COPIES="$MATH_COPIES Sources/Analysis/Statistics.swift(reimplemented)"
fi
# And LAPACK is reached through the one C shim, not from Swift directly — the
# other interface is the one deprecated in macOS 13.3.
LAPACK_CALLERS=$(grep -rln "dsyev\|__CLPK_" Sources --include=*.swift || true)
if [ -n "$MATH_COPIES" ] || [ -n "$LAPACK_CALLERS" ]; then
  fail "a second copy of the statistics arithmetic:$MATH_COPIES $LAPACK_CALLERS"
else
  ok "one incomplete gamma, one incomplete beta, one call into LAPACK"
fi

# ARCHITECTURE §14.2: SwiftUI parses markdown in `Text` only when the argument is
# a string *literal*. Split a long one with `+` and the argument becomes a
# `String`, so `**bold**` stops being emphasis and starts being asterisks on
# screen. Driving found one in the middle of a sentence explaining a privacy
# guarantee; nothing in the test suite can see it. `Text(markdown:)` is the fix
# and this is the rule that keeps it applied.
LITERAL_STARS=$(/usr/bin/python3 - <<'MD'
import re, glob
bad = []
for path in glob.glob('Sources/CoAIWorkspaceApp/*.swift'):
    text = open(path, encoding='utf-8').read()
    # A `Text("…` whose argument runs on with `+` before the closing paren.
    for found in re.finditer(r'Text\((?!markdown:|verbatim:)"(?:[^"\\]|\\.)*"\s*\n?\s*\+', text):
        chunk = text[found.start():found.start() + 600]
        argument = chunk[:chunk.find(')\n')] if ')\n' in chunk else chunk
        if '**' in argument:
            bad.append('%s:%d' % (path.split('/')[-1], text[:found.start()].count('\n') + 1))
print(' '.join(sorted(set(bad))))
MD
)
if [ -n "$LITERAL_STARS" ]; then
  fail "markdown in a concatenated Text will print its own asterisks: $LITERAL_STARS"
else
  ok "bold in a caption is bold, not two asterisks"
fi

# ARCHITECTURE §20.7 / P11.7b: who answered is kept in a different file from what
# they answered, and the server cannot reach the first one at all. Two rules,
# because they defend against different things — the separate file means a copy
# of the response data carries no identities, and the absent dependency means the
# one surface that takes input from strangers has no way to ask who anybody is.
LINKAGE_IN_SERVER=$(grep -rlE "^import Linkage" Sources/FieldServer 2>/dev/null || true)
SAME_FILE=$(/usr/bin/python3 - <<'PATHS'
import re
paths = open('Sources/Config/AppPaths.swift').read()
def file_of(name):
    found = re.search(name + r': URL \{ [a-zA-Z]+\.appending\(path: "([^"]+)"\)', paths)
    return found.group(1) if found else None
answers, identities = file_of('responsesDatabase'), file_of('linkageDatabase')
print('' if answers and identities and answers != identities
      else 'responses=%s linkage=%s' % (answers, identities))
PATHS
)
if [ -n "$LINKAGE_IN_SERVER" ] || [ -n "$SAME_FILE" ]; then
  fail "identities are reachable from the server, or share the answers' file: $LINKAGE_IN_SERVER $SAME_FILE"
else
  ok "who answered lives in its own file, and M16 cannot reach it"
fi

# The other half of that separation, and the half `swift test` cannot see because
# it lives in the app target. Driving the screen found it: the Keychain refused
# the linkage key, the identity step never returned, and the answers table said
# "ยังไม่มีคำตอบ" beside a round header that said forty — with forty rows in the
# database. Answers must reach the screen before anything asks who anybody is.
ANSWER_ORDER=$(/usr/bin/python3 - <<'ORDER'
import re
src = open('Sources/CoAIWorkspaceApp/InstrumentsViewModel.swift').read()
body = src[src.index('public func loadResponses()'):]
body = body[:body.index('\n    /// Records a change')]
rows = body.find('responseRows = submissions.map')
identities = min([p for p in (body.find('await recordResponses'),
                              body.find('await loadParticipants')) if p >= 0] or [-1])
print('' if rows >= 0 and (identities < 0 or rows < identities)
      else 'the answers wait for the identity file')
ORDER
)
if [ -n "$ANSWER_ORDER" ]; then
  fail "$ANSWER_ORDER — §20.7 says the two are independent, so the table must not need the Keychain"
else
  ok "the answers reach the screen without asking who anybody is"
fi

# ARCHITECTURE §19.2 / P10.12, risk R13: collapsing fourteen screens into four
# areas is the same mistake as `Scope.project` if two of them quietly end up with
# no home — a reorganisation reads as finished because the new structure is tidy.
# So every screen §14.2 lists has a row in `IAInventory`, saying which area and
# sub-tab it lives in and whether it is complete. A screen can be dropped by
# deciding to drop it, never by being forgotten.
MISSING_SCREENS=$(/usr/bin/python3 - <<'INVENTORY'
import re
arch = open('ARCHITECTURE.md').read()
table = arch[arch.index('### 14.2 WorkspaceUI'):arch.index('### 14.3 App Intents')]
# Rows look like: | **Chat** | ... |  — with an optional *(ใหม่)* after the name.
names = re.findall(r'^\| \*\*([^*]+)\*\*', table, re.M)
inventory = open('Sources/CoAIWorkspaceApp/IAInventory.swift').read()
missing = [n for n in names if f'screen: "{n}"' not in inventory]
print(' '.join(missing) if missing else '')
INVENTORY
)
if [ -n "$MISSING_SCREENS" ]; then
  fail "หน้าจอใน §14.2 ที่ไม่มีที่อยู่ใน IAInventory (กฎ R13): $MISSING_SCREENS"
else
  ok "every screen in §14.2 has a place in the four areas, or says why not"
fi

# ARCHITECTURE §19.2.4 / P10.16: two things the Plan screen must NOT be able to
# do. Both are absences, and an absence is exactly what rots without a rule.
#
#  • **No dragging a Gantt bar.** The end date is a result of sequencing and real
#    speed, so dragging it is editing the measuring instrument. Wanting it sooner
#    means cutting scope, cutting dependencies, or changing model tier.
#  • **No second accountable.** `RACI.accountable` is one field and `Accountable`
#    has no case that takes a `Role`, so "two A" is not a representable state —
#    the rule here keeps the screen from growing a multi-select that would need a
#    validator to say no.
PLAN_UI="Sources/CoAIWorkspaceApp/ProjectsView.swift"
UI_VIOLATIONS=""
grep -q "DragGesture" "$PLAN_UI" && UI_VIOLATIONS="$UI_VIOLATIONS draggable-schedule"
# The letter list the R/C/I toggles iterate. An `accountable` case in it would
# put A in a row of buttons somebody can tick twice.
if grep -A 3 "enum RACILetter" "$PLAN_UI" | grep -qE "accountable"; then
  UI_VIOLATIONS="$UI_VIOLATIONS accountable-as-a-toggle"
fi
# Plan edits go through change control, never straight to the store: §19.11 says
# a plan cannot move after G2 without a change request, and a second write path
# is a way for it to move without one.
if grep -nE "service\.(save\(package|removePackage)" Sources/CoAIWorkspaceApp/ProjectsViewModel.swift | grep -q .; then
  UI_VIOLATIONS="$UI_VIOLATIONS plan-write-bypassing-change-control"
fi
# ARCHITECTURE §19.2.3 / P10.15: every action in the status bar writes a record.
# The strip can widen a budget or close an exception in one click from any
# screen, which makes it the easiest place in the system for a decision to be
# made and forgotten — so its buttons go through `model.perform`, whose actions
# all record (StatusActionTests iterates them). Any other mutation from this file
# is a way around that.
STATUS_BAR="Sources/CoAIWorkspaceApp/StatusBarView.swift"
if grep -nE "model\.(update|addPackage|removePackage|edit|setTolerance|record|decide|measure|tailor)" "$STATUS_BAR" | grep -q .; then
  UI_VIOLATIONS="$UI_VIOLATIONS status-bar-mutation-without-a-record"
fi
if [ -n "$UI_VIOLATIONS" ]; then
  fail "the Plan screen can do something §19.2.4 says it must not:$UI_VIOLATIONS"
else
  ok "the plan is edited through change control, and what is measured cannot be dragged"
fi

# Every test that needs a database starts its own SurrealDB on its own port, and
# the "on its own" half is not enforced by anything: two servers on one port do
# not collide loudly — the second client connects to the first server's data. The
# two suites that shared 18_631 failed in ways that pointed nowhere near the
# cause (a write conflict in one, an extra search hit in the other) and both
# passed when run alone. A number somebody has to remember not to reuse is a
# number that gets reused.
DUPLICATE_PORTS=$(grep -rhn "port: 18_[0-9]*" Tests \
  | sed 's/.*port: \(18_[0-9]*\).*/\1/' | sort | uniq -d | tr '\n' ' ')
if [ -n "$DUPLICATE_PORTS" ]; then
  fail "two tests share a database port: $DUPLICATE_PORTS"
else
  ok "every database test has a port to itself"
fi

# ARCHITECTURE §19.15 / P10.13: the conformance answer is a `switch` over all
# seventeen ISO 21502 practices, and the compiler only enforces that while there
# is no `default:` in it. A single default arm would turn "every practice has an
# answer" into "every practice has *an* answer, possibly the same nil forever" —
# which is exactly the box-ticking conformance claim §19.16 says this one is not.
PRACTICE_GAPS=$(/usr/bin/python3 - <<'PRACTICES'
import re
src = open('Sources/ProjectKit/Conformance.swift').read()
declaration = src[src.index('public enum Practice'):src.index('public var label')]
cases = re.findall(r'^\s*case (\w+)$', declaration, re.M)
problems = []
if len(cases) != 17:
    problems.append(f'practice-count:{len(cases)}')
# A real arm starts its own line; the words "default:" inside a comment are how
# this file explains why there isn't one.
if re.search(r'^\s*default\s*:', src, re.M):
    problems.append('has-default-arm')
# Each case must be answered in the evidence switch as well as labelled.
evidence = src[src.index('public static func evidence'):src.index('public static func evaluate')]
problems += [f'unanswered:{c}' for c in cases if f'case .{c}:' not in evidence]
print(' '.join(problems))
PRACTICES
)
if [ -n "$PRACTICE_GAPS" ]; then
  fail "the ISO 21502 practice switch is not exhaustive by construction:$PRACTICE_GAPS"
else
  ok "all 17 practices are answered by name, with no default arm"
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

# §21.2 / P12.2 — the six knowledge views are a `switch` over `Role` with no
# `default:`, for the same reason the seventeen practices are. A seventh role
# must be a compiler error, not a role that silently inherits somebody else's
# filter — and "silently inherits the Reviewer's view" means an agent that
# cannot see the material it needs and nothing anywhere saying why.
VIEW_GAPS=$(/usr/bin/python3 - <<'VIEWS'
import re
src = open('Sources/Knowledge/KnowledgeView.swift').read()
roles = re.findall(r'^    case (\w+)$',
                   open('Sources/AgentKit/CoreTypes.swift').read()
                   [open('Sources/AgentKit/CoreTypes.swift').read().index('public enum Role'):][:400],
                   re.M)
block = src[src.index('static func standard(for role: Role)'):]
problems = [f'unanswered:{r}' for r in roles if f'case .{r}:' not in block]
if re.search(r'^\s*default\s*:', block, re.M):
    problems.append('has-default-arm')
print(' '.join(problems))
VIEWS
)
if [ -n "$VIEW_GAPS" ]; then
  fail "the knowledge-view switch is not exhaustive by construction:$VIEW_GAPS"
else
  ok "every role has a knowledge view of its own, with no default arm"
fi

# A test must not guess a port and then bind it.
#
# `SocketTests` used `UInt16.random(in: 49_200...50_800)` and called that "a
# port nobody is using". It is a guess, and it collided often enough to fail one
# full run in three while passing in isolation — the kind of red people learn to
# re-run rather than read. Port 0 asks the system, and `start(serving:port:)`
# reports back what it got, so there is no window between choosing and binding.
# Comment lines skipped, or the note explaining this rule trips it — the same
# way the force-unwrap rule's first version did.
GUESSED_PORTS=$(grep -rn "start(serving:" Tests --include=*.swift \
  | grep -vE ":[0-9]+: *//" | grep -v "anyFreePort" | grep -v "port: 0" || true)
if [ -n "$GUESSED_PORTS" ]; then
  echo "$GUESSED_PORTS" | sed 's/^/   /' | head -5
  fail "a test binds a port it chose itself instead of asking for one (port 0)"
else
  ok "no test guesses a port before binding it"
fi

# The plan's status cells have to agree with themselves.
#
# Marking a task done by *appending* to its status cell leaves the row opening
# with "— ยังไม่เริ่ม" and the ✅ somewhere in the middle — which is what a
# reader scanning the table sees, and what I did to all eight P12 rows in one
# edit. The dashboard is only trustworthy if the first marker in a cell is the
# true one.
STALE_STATUS=$(/usr/bin/python3 - <<'PLAN'
import re
bad = []
for i, line in enumerate(open('IMPLEMENTATION_PLAN.md'), 1):
    m = re.match(r'\| \*\*(P\d+\.\d+[a-z]?)\*\*[^|]*\|[^|]*\|[^|]*\|(.*)\|$', line)
    if not m:
        continue
    task, status = m.group(1), m.group(2).strip()
    if status.startswith('—') and ('✅' in status or '🔶' in status):
        bad.append(f'{task}@{i}')
print(' '.join(bad))
PLAN
)
if [ -n "$STALE_STATUS" ]; then
  fail "a plan row opens with a stale marker and closes with a newer one: $STALE_STATUS"
else
  ok "every task's status cell opens with its real state"
fi

# P12.8 — the coupling that would rot silently.
#
# `ToolProficiencyReader` decides "the rules stopped this" versus "this role got
# it wrong" by matching the prefix `ToolGateway` writes into the span's detail.
# Reword one without the other and refusals quietly start counting as
# incompetence — a number that then goes *up* when the guard rails are loosened.
MISSING_PREFIX=""
for prefix in "policy hard stop" "stage gate" "denied" "plan-only"; do
  grep -q "detail: \"$prefix" Sources/CoreEngine/ToolGateway.swift \
    || MISSING_PREFIX="$MISSING_PREFIX '$prefix'"
done
if [ -n "$MISSING_PREFIX" ]; then
  fail "the proficiency reader looks for span details the gateway no longer writes:$MISSING_PREFIX"
else
  ok "a call the rules stopped is still told apart from a call the role got wrong"
fi

# P14.4 — the tools that ask a person even under full autonomy.
#
# `install_package` runs code nobody here wrote, and an sdist runs it *during*
# installation, so whatever it did appears in no output and in nothing the
# package is later used for. Full autonomy is a decision to accept bad odds
# while nobody is watching, and that trade needs the damage to be visible
# afterwards. Taking this off the list would be silent.
# The name appears twice in this file — once in the risk table, once in the
# list — so the check has to look at the `toolNames` line itself. The first
# version of this rule grepped the whole file and passed happily with the list
# emptied.
if grep -E 'toolNames: Set<String> *=' Sources/CoreEngine/RiskScorer.swift \
   | grep -q '"install_package"'; then
  ok "install_package still stops for a person whatever the autonomy setting"
else
  fail "install_package is no longer on the always-ask list — it would install unattended (P14.4)"
fi

# U33-1 — a sheet whose content force-unwraps the optional that presents it.
#
# `Binding($model.editing)` inside a sheet driven by `model.editing != nil`
# crashes the app on save: setting the optional to nil re-evaluates the sheet's
# body once more before dismissal finishes, and the force-unwrap traps in
# `BindingOperations.ForceUnwrapping.get`. It shipped on two screens and was
# found by pressing the button, because a crash inside SwiftUI's update pass is
# invisible to every test this project has.
# Comment lines are skipped so the note explaining this bug does not trip it.
# Single-quoted and escaped: "Binding(\$" in double quotes becomes `Binding($`,
# where `$` is an end-of-line anchor, which matches every multi-line
# `Binding(get:set:)` in the app and says nothing about force-unwrapping.
if grep -rnE 'Binding\(\$' Sources/CoAIWorkspaceApp --include=*.swift \
   | grep -vE ':[0-9]+: *//' | grep -q .; then
  fail "a force-unwrapping Binding in a view — it traps when the optional is cleared (U33-1)"
else
  ok "no sheet force-unwraps the optional that presents it"
fi

# D6, one layer in: wired into the engine and reachable from no screen.
#
# The rule above catches a capability the app never constructs. It does not
# catch the variant found during P9.3: `Engine` has held a `ChannelAccountStore`
# since P7.3 and **no view ever read it**, so all three chat channels could only
# be configured by editing JSON beside the database. The capability was wired;
# the person was not.
#
# So these engine properties must be read by something that is not Engine.swift.
UNREACHABLE=""
for property in channelAccounts mcpServers templates plugins knowledge conflicts projects; do
  grep -rlq "engine\.$property" --include=*.swift \
    $(ls Sources/CoAIWorkspaceApp/*.swift | grep -v "Engine.swift") \
    || UNREACHABLE="$UNREACHABLE $property"
done
if [ -n "$UNREACHABLE" ]; then
  fail "on the engine but on no screen — configurable only by editing files:$UNREACHABLE"
else
  ok "everything a person configures has a screen, not just a store"
fi

# P9.3 / risk R11 — the two ways the secrets work quietly comes undone.
#
# 1. The vault is installed at boot. Without this line every secret in the app
#    falls back to an environment a Finder-launched `.app` does not have
#    (measured: `launchctl getenv` returns nothing), and every paid endpoint,
#    bot and connector goes back to being configurable but unusable — the D6
#    shape this project has now hit eight times.
if grep -q "SecretStore.install(" Sources/CoAIWorkspaceApp/Engine.swift; then
  ok "the app installs a secret vault before anything reads a secret"
else
  fail "the app never installs a secret vault — every key would be unreachable (P9.3)"
fi

# 2. Nothing that holds a secret reads one straight from the environment.
#    `EndpointRegistry.apiKey` did exactly that, which made "the one place a
#    secret is looked up" two places — and the second one saw neither the
#    Keychain nor a test override. Process-launch plumbing (Execution, Sidecar,
#    MCPBridge's `ExecutableSearch` default) legitimately reads the environment
#    and is not in scope here.
STRAY_ENV=$(grep -rln "processInfo.environment" Sources/Config Sources/Channels \
  Sources/Analysis --include=*.swift || true)
if [ -n "$STRAY_ENV" ]; then
  fail "a secret-bearing module reads the environment directly instead of SecretStore: $STRAY_ENV"
else
  ok "every secret goes through SecretStore, so the Keychain is really the one source"
fi

# 3. The audit that proves no store writes a secret to disk still exists. It is
#    the only check of a property no single module owns, so deleting the target
#    would silently retire P9.3's Done-when.
if grep -q '"SecretsAuditTests"' Package.swift; then
  ok "the secrets-on-disk audit is still part of the test suite"
else
  fail "the SecretsAuditTests target is gone — nothing checks that secrets stay off disk (P9.3)"
fi

# P10.15 — the four ways assignment spans go back to being nothing.
#
# 1. The lead is handed the span sink. `spans:` is an optional argument with a
#    default of nil, so dropping it at the one construction site compiles, runs,
#    passes every test in CoreEngine (they pass their own sink) and silently
#    turns the whole feature off: the schedule loses its durations and the
#    forecast band quietly falls back to chat turns. D6 again, and this time the
#    hole is a default argument rather than a missing screen.
#    The range stops at the closing brace of the factory, not at the first `)`:
#    the first version of this rule ran to end of file and passed happily with
#    the argument deleted, because `spans:` appears again further down. The lead
#    is built inside `WorkspaceTeams`'s factory since P21.2 — one per workspace —
#    so that block is the construction site now.
if awk '/let teams = WorkspaceTeams \{/,/^        \}$/' Sources/CoAIWorkspaceApp/Engine.swift \
   | grep -q "spans:"; then
  ok "the team writes spans, so its work has a duration anybody can read"
else
  fail "TeamOrchestrator is built without a span sink — team work would record no time (P10.15)"
fi

# 2. No query names a span kind in a string literal. `durations(forRole:)` was
#    written against `name = 'turn'` while nothing agreed that was the name, and
#    before that against no name filter at all — so a schedule was drawn from a
#    p90 of `kb_search` calls. A reader that greps for a string the writer no
#    longer emits does not fail; it returns the wrong population.
LITERAL_SPAN_NAME=$(grep -n "name = '" Sources/Persistence/SurrealSpanSink.swift || true)
if [ -n "$LITERAL_SPAN_NAME" ]; then
  echo "$LITERAL_SPAN_NAME" | sed 's/^/   /'
  fail "a span query hardcodes a span name — use Span.assignmentName/turnName (P10.15)"
else
  ok "the forecast asks for the span names the writers actually emit"
fi

# 3. The time popover reads what the band is made of rather than asserting it.
#    The sentence beside this band has been wrong twice — "งานชนิดเดียวกัน" over
#    a band of tool calls, then over a band of chat turns — both times because
#    the claim lived on the screen and the population lived three modules away.
if grep -q "forecast.basis" Sources/CoAIWorkspaceApp/StatusBarView.swift; then
  ok "the forecast band names its own population instead of the screen guessing"
else
  fail "the time popover describes the band without reading its basis (P10.15)"
fi

# 4. The work-package picker on the team screen reaches the run. `run` takes
#    `workPackage:` with a default of nil, so a picker that is read by nothing
#    looks like it works and files every hour under no promise — which is the
#    state `LedgerRow.work_package` was already in for four plan items.
if awk '/team.run\(/,/\) \{ event in/' Sources/CoAIWorkspaceApp/TeamViewModel.swift \
   | grep -q "workPackage:"; then
  ok "the leaf the team screen shows is the leaf the run is filed under"
else
  fail "the team screen's work-package picker is not passed to the run (P10.4/P10.15)"
fi

# Every script in scripts/ at least parses.
#
# `gx10-serve.sh` runs on another machine and nothing here ever executes it, so
# a syntax error in it would sit undiscovered until the one moment somebody
# needs the endpoint back up. Parsing is not correctness, but it is the half
# that can be checked from here.
BROKEN_SCRIPTS=""
for script in scripts/*.sh; do
  bash -n "$script" 2>/dev/null || BROKEN_SCRIPTS="$BROKEN_SCRIPTS $script"
done
if [ -n "$BROKEN_SCRIPTS" ]; then
  fail "a shell script does not parse:$BROKEN_SCRIPTS"
else
  ok "every script in scripts/ parses, including the ones that run elsewhere"
fi

# P21.1 — a project is a tab, not a mode.
#
# The app held one `selection` and rebuilt every screen on change, so opening
# the second project cost you the first. Two ways that comes back:
#
# 1. A stored single selection reappears on the view model. `selection` still
#    exists as a *computed* reading of `workspaces.active`, which is fine — a
#    stored one is the thing that cannot hold two.
if grep -nE "var selection: Selection = |var selection: Selection\?" \
   Sources/CoAIWorkspaceApp/ProjectsViewModel.swift | grep -q .; then
  fail "the project selection went back to a single stored value — tabs cannot hold two (P21.1)"
else
  ok "which workspace is in front is read from the open set, not stored beside it"
fi

# 2. The tab strip is on screen. `OpenWorkspaces` can hold ten workspaces and
#    be reachable from nothing, which is D6 in its usual shape: the capability
#    exists and the person cannot get at it.
if grep -rlq "WorkspaceTabBar(" \
   $(ls Sources/CoAIWorkspaceApp/*.swift | grep -v "CoAIWorkspaceApp.swift") \
   2>/dev/null || grep -q "WorkspaceTabBar(projects:" Sources/CoAIWorkspaceApp/CoAIWorkspaceApp.swift; then
  ok "the open workspaces are drawn somewhere a person can click them"
else
  fail "nothing renders the workspace tab bar — projects would be openable and invisible (P21.1)"
fi

# P21.2 — the work belongs to the workspace, not to the screen.
#
# Three ways this comes back, and each has been the shape of a real bug here:
#
# 1. A single lead for the whole app. It was one `TeamOrchestrator` re-pointed
#    with `use(scope:)` on every switch — which mid-run is refused, so the tab
#    you switched *to* filed its rows under the project you left. `team(for:)`
#    is the only way to reach one now.
if grep -rnE "engine\.team([^s(]|$)" Sources/CoAIWorkspaceApp/*.swift | grep -q .; then
  grep -rnE "engine\.team([^s(]|$)" Sources/CoAIWorkspaceApp/*.swift | sed 's/^/   /' | head -3
  fail "a screen reached for one app-wide team lead — it belongs to a workspace (P21.2)"
else
  ok "the team lead is asked for by workspace, never shared across them"
fi

# 2. A per-workspace model comes back as one shared instance on the root view.
#    That is the state the app was in: one `TeamViewModel`, one
#    `AnalysisViewModel`, re-pointed at whichever project was in front, so the
#    rows of the one you left merged into the one you arrived at.
SHARED_MODELS=$(grep -nE \
  "@State private var (team|analysis|manuscripts|instruments|coding|workflows|knowledge) = " \
  Sources/CoAIWorkspaceApp/CoAIWorkspaceApp.swift)
if [ -n "$SHARED_MODELS" ]; then
  echo "$SHARED_MODELS" | sed 's/^/   /' | head -5
  fail "a workspace's screen model is held once for the whole app (P21.2)"
else
  ok "every scoped screen model comes from the per-workspace registry"
fi

# 3. Closing a tab throws away work that is still running. Closing a tab closes
#    a window, not the project (§19.1.1) — and not the run either: the release
#    path is what refuses to let go of a busy workspace, so a close that skips
#    it would leave the run writing rows with nothing on screen able to see it.
if grep -q "workspaces.release(" Sources/CoAIWorkspaceApp/CoAIWorkspaceApp.swift \
   && grep -q "teams.release(" Sources/CoAIWorkspaceApp/CoAIWorkspaceApp.swift; then
  ok "closing a tab lets go of its models and its lead, and both refuse while busy"
else
  fail "closing a tab never releases its workspace — or does it without the busy check (P21.2)"
fi

# P21.3 — every write to a project goes past the archive guard.
#
# Closing has been a gate with eight conditions since P10.10, and until now
# nothing stopped anybody editing the project afterwards — which makes the
# closing report a claim about a state that moved after it was written. The
# guard is easy to forget on the *next* write method somebody adds, and the
# symptom is silent: the write just works.
#
# So every public mutating entry point on ProjectService must either call
# `requireWritable` or be one of the two documented exceptions:
#   • `measure`/`save(_ benefit:)` — §19.12's post-project review adds a fact
#     rather than changing an agreement, and it is dated months after closing;
#   • `persist` — the primitive the closing transition itself writes through.
UNGUARDED=$(awk '
  /^    public func (update|save|record|remove|complete|decideChange)/ { fn=$0; body=""; depth=0 }
  fn != "" { body = body "\n" $0 }
  fn != "" && /^    }/ {
    if (body !~ /requireWritable/ && body !~ /benefit/ && body !~ /Benefit/)
      print fn
    fn=""
  }
' Sources/ProjectKit/ProjectService.swift | sed 's/^ *//')
if [ -n "$UNGUARDED" ]; then
  echo "$UNGUARDED" | sed 's/^/   /'
  fail "a write to a project that never checks whether it was closed (P21.3)"
else
  ok "every project write goes past the archive guard, or is a documented exception"
fi

# P20.3 — the layer a number is read off is never translucent.
#
# §24.2's honest materiality, and in this app it is not a matter of taste: the
# screens show p-values, confidence intervals, money and elapsed time, and a
# figure misread because content scrolled under it is what somebody then
# decides with. Glass is for chrome that floats above content; anything
# carrying a number sits on a solid layer.
#
# Enforced in two halves, because "is this on glass" has to be answerable:
#
# 1. Translucency is declared through `Surface`, never applied raw — so one
#    grep answers the question for the whole app.
RAW_GLASS=$(grep -rnE "\.background\(\.(bar|ultraThinMaterial|regularMaterial|thinMaterial|thickMaterial)\)|\.glassEffect\(" \
  Sources/CoAIWorkspaceApp/*.swift | grep -v "DesignTokens.swift" || true)
if [ -n "$RAW_GLASS" ]; then
  echo "$RAW_GLASS" | sed 's/^/   /' | head -4
  fail "a view applies a translucent background directly instead of declaring its layer (§24.2, P20.3)"
else
  ok "every translucent background is declared through Surface, so the layer is greppable"
fi

# 2. A file that formats a number does not float. The heuristic is deliberately
#    blunt — any `%.Nf` in the same file as `Surface.floating` — because the
#    cost of a false alarm here is a comment and the cost of a miss is a
#    misread p-value.
FLOATING_NUMBERS=""
for file in Sources/CoAIWorkspaceApp/*.swift; do
  grep -q "surface(.floating" "$file" 2>/dev/null || continue
  grep -qE "%\.[0-9]+f" "$file" 2>/dev/null && FLOATING_NUMBERS="$FLOATING_NUMBERS $(basename "$file")"
done
if [ -n "$FLOATING_NUMBERS" ]; then
  echo "  $FLOATING_NUMBERS" | sed 's/^/  /'
  fail "a view puts formatted numbers on a floating (glass) layer (§24.2, P20.3)"
else
  ok "numbers are drawn on solid layers, never on glass"
fi

# 3. Installing an R package is on the always-ask list, and `r_eval` cannot be
#    used to route around it — the list is keyed on the tool name, and
#    `install.packages(...)` inside a block of R is not a tool name (P14.4).
if grep -q '"r_install_package"' Sources/CoreEngine/RiskScorer.swift \
   && grep -q "refuseInstalls" Sources/ToolBelt/RTool.swift; then
  ok "an R package install stops for a person, and r_eval cannot smuggle one past"
else
  fail "r_eval can install packages without the always-ask tool (§5.5, P14.4)"
fi

# P3.7 — a decision history that can be gone back on, and not edited.
#
# The failure mode is an UPDATE: reversing a decision by overwriting the old
# one leaves a card that says what we think now and cannot say what we thought
# before, which is the whole reason §11.6 asks for a history at all.
if grep -q "CREATE conflict_decision" Sources/Persistence/ConflictStore.swift \
   && ! grep -qE "(DELETE|UPDATE) conflict_decision" Sources/Persistence/ConflictStore.swift; then
  ok "the conflict history is append-only — a reversal adds an entry"
else
  fail "something edits or deletes conflict history instead of appending (§11.6, P3.7)"
fi

# P4.8 — a run that stops on budget says so.
#
# The failure mode is silence: a run that quietly returns fewer deliverables
# looks exactly like a run that found less to do, and the work it never
# started is invisible unless it is written into the ledger.
if grep -q "case budgetExhausted" Sources/CoreEngine/TeamOrchestrator.swift \
   && grep -q "budgetExhausted" Sources/CoAIWorkspaceApp/TeamViewModel.swift; then
  ok "hitting the token ceiling reaches the screen instead of shortening the run silently"
else
  fail "a run can stop on its token ceiling without telling anybody (§5.5, P4.8)"
fi

# P9.5 — the main actor does not do file work.
#
# Measured (E.29): decoding a 24 MB archive on the main actor stalls it for
# 81.6 ms — five dropped frames, which reads as the app having hung — against
# 2.6 ms with the same work moved off. Nothing bounds the size of somebody's
# knowledge base, so this only gets worse with use.
#
# The rule is about where the work runs, not whether somebody remembered to
# think about it: a synchronous read, write or encode inside an @MainActor view
# model is a stall, and the fix is one `Task.detached` away.
BLOCKING=$(grep -rnE "Data\(contentsOf:|String\(contentsOf:|\.write\(to:|DispatchQueue\.main\.sync|waitUntilExit\(\)" \
  Sources/CoAIWorkspaceApp/*.swift | grep -v "Task.detached" || true)
# A write inside a detached block is fine; the grep above cannot see the block,
# so the check is on the three lines above each hit.
STALLS=""
for hit in $(echo "$BLOCKING" | grep -oE "^[^:]+:[0-9]+" || true); do
  file="${hit%%:*}"; line="${hit##*:}"
  start=$(( line > 4 ? line - 4 : 1 ))
  sed -n "${start},${line}p" "$file" | grep -q "Task.detached" || STALLS="$STALLS $hit"
done
if [ -n "$STALLS" ]; then
  echo "$STALLS" | tr ' ' '\n' | sed 's/^/   /' | head -5
  fail "a view model reads or writes a file on the main actor (§24, P9.5)"
else
  ok "file work in view models runs off the main actor"
fi

# P14 — R is a bridge, not a dependency.
#
# 1. The statistics stay Swift. The plan says R blocks nobody, and the way that
#    stops being true is one `import RBridge` inside the analysis layer: from
#    then on a machine without R has a broken statistics screen.
R_LEAK=$(grep -rln "import RBridge" Sources/Analysis Sources/StatKit Sources/CoreEngine \
  Sources/Instruments 2>/dev/null || true)
if [ -n "$R_LEAK" ]; then
  echo "$R_LEAK" | sed 's/^/   /'
  fail "a statistics module now depends on R being installed (§12.7, P14)"
else
  ok "the statistics layer does not depend on R"
fi

# 2. The setup helper says how to install and does not install. A helper that
#    runs install.packages to turn its own light green has changed the person's
#    machine to pass its own check (§19.15, P14.4).
#    Checked as execution rather than as a word: the advice string names the
#    command on purpose, and a rule that cannot tell advice from a spawn would
#    force the helper to be vaguer than it should be.
INSTALLS=$(grep -rn "install.packages" Sources --include=*.swift \
  | grep -E "run\(|Process\(|arguments:|executableURL" || true)
if [ -n "$INSTALLS" ]; then
  echo "$INSTALLS" | sed 's/^/   /' | head -3
  fail "something in Sources runs install.packages instead of telling the person to (P14.1)"
else
  ok "R packages are the person's to install; the app only says which"
fi

# P20.6 — the screen leans on the type the person declared, and on nothing else.
#
# 1. Emphasis cannot reach usage. The spans record every screen anybody opens,
#    so "move the panels they use most to the front" is always one import away
#    — and it is how a layout stops being learnable.
#    Comments are stripped first: this file argues about usage-based
#    adaptation at length, and a rule that cannot tell the argument from the
#    behaviour would be a rule against explaining yourself.
BEHAVIOUR=$(grep -vE "^\s*//" Sources/ProjectKit/PanelEmphasis.swift \
  | grep -nE "import (Persistence|Observability)|[Ss]pan|frequency|usage|history|Count" || true)
if [ -n "$BEHAVIOUR" ]; then
  echo "$BEHAVIOUR" | sed 's/^/   /' | head -3
  fail "panel emphasis reads behaviour instead of the declared project type (§24.3, P20.6)"
else
  ok "panel emphasis has one input: the project type the person chose"
fi

# 2. Emphasis marks panels; it never reorders them. A list built from the
#    emphasis is a screen that rearranges itself, which is the same problem in
#    a nicer suit.
TAB_LISTS=$(awk '/private var subTabs/,/private var subTabSelection/' \
  Sources/CoAIWorkspaceApp/CoAIWorkspaceApp.swift | grep -ic "mphasis" || true)
if [ "$TAB_LISTS" != "0" ]; then
  fail "the sub-tab list is built from the project type — emphasis must mark, not reorder (P20.6)"
else
  ok "sub-tabs stay in one order for every project type"
fi

# 3. A panel named in the emphasis that the app no longer draws is a highlight
#    pointing at nothing.
MISSING=""
for panel in $(grep -oE "case [a-zA-Z, ]+$" Sources/ProjectKit/PanelEmphasis.swift \
               | sed 's/case //' | tr ',' ' '); do
  grep -qE "case .*\b$panel\b" Sources/CoAIWorkspaceApp/CoAIWorkspaceApp.swift \
    || MISSING="$MISSING $panel"
done
if [ -n "$MISSING" ]; then
  echo "  $MISSING" | sed 's/^/  /'
  fail "emphasis names a panel the app does not have:$MISSING (P20.6)"
else
  ok "every emphasised panel is a panel the app actually draws"
fi

# P20.5 — the reason shown is the decision, not a story about it.
#
# The failure this guards against is specific and easy to reach: a second
# function (or a model) that describes the routing rules in prose. It reads
# well, it passes review, and it goes stale the first time a filter changes —
# leaving a screen that confidently explains a choice the router did not make.
#
# 1. One selection pass. If the capability filter appears twice in the router,
#    one of them is an explanation pretending to be a decision.
PASSES=$(grep -c "capabilities.supportsTools" Sources/LLMProviders/ModelRouter.swift)
if [ "$PASSES" != "1" ]; then
  fail "ModelRouter has $PASSES capability filters — the routing reason must come from the pass that routes (P20.5)"
else
  ok "the router explains itself from the same pass that chooses"
fi

# 2. The wire to the screen. `routed` carrying an empty `why` compiles fine and
#    shows a tier with no reason beside it.
if grep -q "why: routed.choice.lines" Sources/CoreEngine/AgentTurnRunner.swift \
   && grep -q "why = outcome.rationale" Sources/CoreEngine/AgentTurnRunner.swift; then
  ok "the tier's rule and the gate's risk score both reach the turn's events"
else
  fail "a turn reports what it did without why it did it (§24.3, P20.5)"
fi

# P20.2 — the design system is enforced, or it is another document.
#
# §24.1 names consistency as the worst of this app's four HIG problems, and the
# cause is in the history: screens were built one at a time in task order, so
# spacings of 4, 6, 8, 10 and 12 are all present and none of them was chosen.
# `DesignTokens.swift` is where the numbers live now.
#
# The list below is the debt, spelled out: every view file that predates the
# system and still writes its own numbers. **It may only shrink.** A file not on
# it that hardcodes a padding, a corner radius or a raw colour fails — which is
# what stops the token file from becoming one more good intention (P20.2's
# Done-when).
LEGACY_VIEWS="AnalysisView.swift ApprovalBanner.swift BootStatusView.swift ChannelsView.swift ChatView.swift CoAIWorkspaceApp.swift CodingView.swift ConflictView.swift EndpointsView.swift EntityGraphView.swift FilesView.swift IAInventory.swift InstrumentsView.swift KnowledgeBaseView.swift MCPServersView.swift ManuscriptView.swift ModelsView.swift ParticipantsBox.swift ProjectsView.swift ResponsesBox.swift SourcesView.swift StatusBarView.swift TeamView.swift WorkflowView.swift"
UNTOKENISED=""
for file in Sources/CoAIWorkspaceApp/*.swift; do
  name="$(basename "$file")"
  [ "$name" = "DesignTokens.swift" ] && continue
  case " $LEGACY_VIEWS " in *" $name "*) continue ;; esac
  if grep -qE "\.padding\([0-9]|cornerRadius: [0-9]|Color\(red:" "$file"; then
    UNTOKENISED="$UNTOKENISED $name"
  fi
done
if [ -n "$UNTOKENISED" ]; then
  echo "  $UNTOKENISED" | sed 's/^/  /'
  fail "a view writes its own spacing or colour instead of using the design tokens (§24, P20.2)"
else
  ok "every view outside the legacy list uses the design tokens"
fi

# P17.5 — what the driver reads off the screen never becomes an instruction.
#
# §23.2 rule 4. The protection is structural rather than textual: a tool result
# is data by the protocol the model reads, and a system message is instructions.
# Screen text on the second side is prompt injection with a mouse and a
# keyboard, and no amount of careful wording in the envelope fixes it.
#
# So: nothing may build a system or user message out of a screen snapshot.
if grep -rnE "LLMMessage\(\.(system|user).*(snapshot|spokenLines|ScreenText)" Sources \
   | grep -q .; then
  grep -rnE "LLMMessage\(\.(system|user).*(snapshot|spokenLines|ScreenText)" Sources \
    | sed 's/^/   /' | head -3
  fail "screen text was put on the instruction side of the conversation (§23.2, P17.5)"
else
  ok "screen text reaches the model as tool output, never as an instruction"
fi

# P21.4 — participants' words do not follow a project into the shared library.
#
# The rule is ethical and the code is the only place it is enforced: a
# transcript and a journal article are both text in one index, the same shape
# and the same size, and only `Origin` says which of them may travel. Two ways
# that protection disappears without anybody meaning it to:
#
# 1. `.fieldwork` stops being answered with `stays`.
if grep -A 6 "case \.fieldwork:" Sources/Knowledge/ClosingHandover.swift \
   | grep -q "return \.stays"; then
  ok "fieldwork stays with the project the people who gave it agreed to"
else
  fail "participant data is no longer refused at the closing handover (§19.1.1, P21.4)"
fi

# 2. A `default:` arm appears, so the next `Origin` case — a new kind of source,
#    a new import path — is decided by whatever the fallback happens to be
#    rather than by somebody asking whether it may be published.
if grep -q "default:" Sources/Knowledge/ClosingHandover.swift; then
  fail "the handover rule grew a default arm — a new source kind would inherit somebody else's answer (P21.4)"
else
  ok "every kind of source is answered by name in the handover rule"
fi

# P18.1 — the conflict criteria are three conditions, not one opinion.
#
# §11.7 borrows NLI's definition: a contradiction needs the same question, a
# real mutual exclusion, and the same context — all three. It was one
# `contradicts` boolean with the conditions described in the prompt, which asks
# a model to do the reasoning *and* the bookkeeping and leaves nothing to check
# afterwards. The pressure to go back is real, because one boolean is simpler
# every time somebody touches this file.
MISSING_CRITERIA=""
for condition in sameQuestion mutuallyExclusive sameContext isTranslation; do
  grep -q "\"$condition\"" Sources/CoreEngine/ConflictDetector.swift \
    || MISSING_CRITERIA="$MISSING_CRITERIA $condition"
done
if [ -n "$MISSING_CRITERIA" ]; then
  fail "the conflict schema stopped asking:$MISSING_CRITERIA (§11.7, P18.1)"
else
  ok "a conflict card still needs all three NLI conditions, and says so in the schema"
fi

# P15.2b — the model's thinking is cut in exactly one place.
#
# The rule is not "cut it" — it is *where*. A `<think>` tag reaching a screen is
# a bug anybody can fix locally, and the fix that suggests itself is stripping
# it in the view that noticed. Do that twice and the tags are being cut in two
# places, differently, and the third screen still shows them. `ReasoningSplitter`
# is the one place; everywhere else the two are already separate values.
STRAY_THINK=$(grep -rnE '"</?think' Sources \
  | grep -v "Sources/LLMProviders/ReasoningSplitter.swift" || true)
if [ -n "$STRAY_THINK" ]; then
  echo "$STRAY_THINK" | sed 's/^/   /' | head -5
  fail "something outside ReasoningSplitter knows what a <think> tag looks like (P15.2b)"
else
  ok "the model's thinking is separated in one place, for both tiers"
fi

# P15.1/P15.3 — what the endpoint is, the endpoint says.
#
# Both numbers used to be written into Swift: a 32k window on every executor and
# a 16k prompt budget beside it. Changing `--max-model-len` on the server moved
# neither, and lowering it made the app overflow a window it believed was
# bigger. The failure is silent in both directions, which is why it is a rule
# rather than a comment.
#
# 1. The prompt budget is a value, not a literal at the call.
if grep -nE "ContextManager\(budget: [0-9]" Sources/CoAIWorkspaceApp/Engine.swift | grep -q .; then
  grep -nE "ContextManager\(budget: [0-9]" Sources/CoAIWorkspaceApp/Engine.swift | sed 's/^/   /'
  fail "the context budget is written into the app again instead of read from the server (P15.3)"
else
  ok "the prompt budget is computed from the window the server reports"
fi

# 2. The executor is told the window that was measured, not a constant. The
#    fallback constant is allowed and expected — a server that reports nothing
#    has to leave the app with something — but `maxModelLength` has to be what
#    is asked first.
if awk '/executors.append\(VLLMExecutor\(/,/^        }$/' Sources/CoAIWorkspaceApp/Engine.swift \
   | grep -q "maxModelLength"; then
  ok "each endpoint's context window comes from its own /v1/models reply"
else
  fail "an executor is built with a hardcoded context window (P15.3)"
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
