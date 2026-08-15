#!/usr/bin/env bash
# Prove the Tier 1 endpoint can do the three things the app depends on.
#
#   ./scripts/gx10-check.sh [host:port]      (default 192.168.1.205:8000)
#
# Runs from anywhere — the Mac included. This exists because "the server is
# up" has twice not meant "the app will work":
#
#   • tool calling disabled  → every request with `tools` got a 400
#   • tool calling with the wrong parser → 200 every time, `tool_calls` null,
#     and the whole agent system silently degraded to a chatbot
#
# The second one is why this script asserts on the *parsed* result rather than
# on the status code. A check that only asks "did it answer" would have passed
# on both bad days.
set -uo pipefail

ENDPOINT="${1:-192.168.1.205:8000}"
BASE="http://$ENDPOINT"
FAILED=0
ok()   { echo "   ✓ $1"; }
fail() { echo "   ✗ $1"; FAILED=1; }

say() { echo; echo "── $1 ──"; }

# ── 1. reachable, and what does it say it is ─────────────────
say "endpoint"
MODELS="$(curl -s --max-time 15 "$BASE/v1/models")" || true
if [ -z "$MODELS" ]; then
  fail "no answer from $BASE — is vllm running?"
  echo; echo "CHECK FAILED"; exit 1
fi
MODEL_ID="$(python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" <<<"$MODELS" 2>/dev/null)"
MAX_LEN="$(python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0].get('max_model_len'))" <<<"$MODELS" 2>/dev/null)"
ROOT="$(python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0].get('root'))" <<<"$MODELS" 2>/dev/null)"
[ -n "$MODEL_ID" ] && ok "serving $MODEL_ID" || fail "could not read the model list"
echo "     weights: $ROOT"

# The app reads this instead of holding a hardcoded budget, and the ceiling
# includes output — see ARCHITECTURE §5.6.1.
if [ "$MAX_LEN" = "None" ] || [ -z "$MAX_LEN" ]; then
  fail "/v1/models does not report max_model_len — ContextManager would have to guess"
else
  ok "max_model_len readable from the endpoint: $MAX_LEN"
fi

ask() {   # ask <json-file> → response on stdout
  curl -s --max-time 240 "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' -d @"$1"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 2. tool calling ──────────────────────────────────────────
# Every specialist works by calling tools. If this is wrong the system does not
# fail — it quietly becomes a chatbot with opinions about databases.
say "tool calling"
cat > "$TMP/tool.json" <<JSON
{"model":"$MODEL_ID","max_tokens":400,"temperature":0,
 "messages":[{"role":"user","content":"ค้นหาจำนวนผู้ป่วยเบาหวานในคลังข้อมูล"}],
 "tools":[{"type":"function","function":{"name":"lookup_patient_count",
   "description":"นับจำนวนผู้ป่วยตามกลุ่มโรค",
   "parameters":{"type":"object","properties":{"cohort":{"type":"string"}},"required":["cohort"]}}}]}
JSON
ask "$TMP/tool.json" > "$TMP/tool.out"
python3 - "$TMP/tool.out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d:
    print("   ✗ %s" % d["error"]["message"][:200]); sys.exit(1)
m = d["choices"][0]["message"]
calls = m.get("tool_calls")
content = m.get("content") or ""
if calls:
    fn = calls[0]["function"]
    print("   ✓ tool_calls parsed: %s(%s)" % (fn["name"], fn["arguments"][:80]))
    try:
        json.loads(fn["arguments"])
        print("   ✓ arguments are valid JSON")
    except Exception:
        print("   ✗ arguments are not JSON: %r" % fn["arguments"][:120]); sys.exit(1)
    sys.exit(0)
# The failure that answers 200. Name what it emitted so the fix is one line.
print("   ✗ tool_calls is null — the parser did not match what the model wrote")
if "<function=" in content or "<tool_call>" in content:
    print("     the model wrote XML, so this needs --tool-call-parser qwen3_xml")
print("     content was: %r" % content[:200])
sys.exit(1)
PY
[ $? -eq 0 ] && ok "a tool call survives the round trip" || fail "tool calling is not usable"

# ── 3. the model's scratchpad ────────────────────────────────
# This model thinks out loud and closes with `</think>`. Without a reasoning
# parser that monologue lands in `content`, and every screen showing model
# text prints it in English above the Thai answer.
say "reasoning split"
cat > "$TMP/think.json" <<JSON
{"model":"$MODEL_ID","max_tokens":700,"temperature":0,
 "messages":[{"role":"user","content":"2+2 เท่ากับเท่าไร ตอบสั้นที่สุด"}]}
JSON
ask "$TMP/think.json" > "$TMP/think.out"
python3 - "$TMP/think.out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["choices"][0]["message"]
content = (m.get("content") or "").strip()
# vLLM 0.27 calls it `reasoning`; older builds `reasoning_content`. Watching
# only one name returns nil, which reads exactly like a model that did not think.
reasoning = m.get("reasoning") or m.get("reasoning_content") or ""
bad = ("</think>" in content) or ("User asks" in content) or ("We need" in content)
if bad:
    print("   ✗ the scratchpad leaked into content — set --reasoning-parser")
    print("     content: %r" % content[:160]); sys.exit(1)
if not content:
    print("   ✗ content is empty (finish_reason=%s)" % d["choices"][0].get("finish_reason"))
    print("     %d chars of reasoning and no answer — thinking spent the whole"
          " max_tokens budget" % len(reasoning)); sys.exit(1)
print("   ✓ content holds only the answer: %r" % content[:60])
print("   ✓ reasoning kept separately (%d chars)" % len(reasoning))
sys.exit(0)
PY
[ $? -eq 0 ] && ok "the model's thinking stays out of the answer" \
             || fail "the scratchpad is not separated"

# ── 4. structured output ─────────────────────────────────────
# The planner and half a dozen other paths ask for a schema.
say "structured output"
cat > "$TMP/schema.json" <<JSON
{"model":"$MODEL_ID","max_tokens":500,"temperature":0,
 "messages":[{"role":"user","content":"แตกเป้าหมายนี้เป็นงานย่อย: ทบทวนวรรณกรรมเรื่องภาวะหมดไฟ"}],
 "response_format":{"type":"json_schema","json_schema":{"name":"TeamPlan","schema":
   {"type":"object","properties":{"assignments":{"type":"array","items":
     {"type":"object","properties":{"role":{"type":"string","enum":["researcher","analyst","engineer","writer"]},
      "goal":{"type":"string"}},"required":["role","goal"]}}},"required":["assignments"]}}}}
JSON
ask "$TMP/schema.json" > "$TMP/schema.out"
python3 - "$TMP/schema.out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d:
    print("   ✗ %s" % d["error"]["message"][:200]); sys.exit(1)
try:
    parsed = json.loads(d["choices"][0]["message"]["content"])
except Exception as error:
    print("   ✗ not decodable JSON: %s" % error); sys.exit(1)
roles = [a.get("role") for a in parsed.get("assignments", [])]
print("   ✓ decoded, %d assignment(s): %s" % (len(roles), roles))
sys.exit(0)
PY
[ $? -eq 0 ] && ok "a response schema comes back decodable" || fail "structured output is broken"

# ── 5. speed, because it decides what is buildable ───────────
# ~4.7 tok/s (bf16) makes a multi-team organisation unusable; ~11.8 (NVFP4)
# does not. This prints the number rather than judging it — the judgement is
# in ARCHITECTURE §17.1 and it is a decision, not a threshold.
say "throughput"
START=$(date +%s)
ask "$TMP/schema.json" > "$TMP/speed.out"
ELAPSED=$(( $(date +%s) - START ))
TOKENS="$(python3 -c "
import json,sys
d=json.load(open('$TMP/speed.out'))
print((d.get('usage') or {}).get('completion_tokens') or 0)" 2>/dev/null)"
if [ "${TOKENS:-0}" -gt 0 ] && [ "$ELAPSED" -gt 0 ]; then
  echo "     $TOKENS tokens in ${ELAPSED}s ≈ $(( TOKENS / ELAPSED )) tok/s (single stream)"
  ok "generation measured"
else
  fail "could not measure throughput"
fi

# ── 6. the metrics the EOC dashboard reads ───────────────────
# §22.6: "Busy" must be measured from the server, not reported by an agent.
say "metrics"
# Captured before matching rather than piped into `grep -q`: under `pipefail`,
# grep exiting on its first hit sends SIGPIPE to curl, and the pipeline reports
# the *curl* failure. This check reported "/metrics is not exposed" against a
# server that was serving it perfectly — a checker that cries wolf gets turned
# off, which costs more than the check was worth.
METRICS="$(curl -s --max-time 10 "$BASE/metrics")"
if grep -q "vllm:num_requests_running" <<<"$METRICS"; then
  ok "/metrics exposes num_requests_running — Busy can be measured, not claimed"
else
  fail "/metrics is not exposed — the Command Tree would have to trust self-reports"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "ENDPOINT READY"; else echo "CHECK FAILED"; fi
exit $FAILED
