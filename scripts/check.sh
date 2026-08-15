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
                  CodebookStore CodingAnalysis CellRunStore ManuscriptBuilder; do
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
