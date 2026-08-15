#!/usr/bin/env bash
# Serve the project's Tier 1 model on the GX10 (ARCHITECTURE §17.1).
#
# Run this ON the GX10 (192.168.1.205), not on the Mac.
#
# Why a script rather than a command in a note: the endpoint has come up twice
# now looking healthy while something the app depends on was silently off.
#
#   1. bf16 run, 2026-08-15 — tool calling not enabled at all. Every request
#      carrying `tools` got a 400, which at least announced itself.
#   2. NVFP4 run, 2026-08-16 — tool calling enabled with the WRONG parser.
#      The model emitted `<function=…><parameter=…>` XML, `tool_calls` came
#      back null, and the server answered 200 every single time. Nothing was
#      broken from the outside; the system simply read it as an agent that
#      never chose to call a tool.
#
# The second failure is the reason this script picks parser names by asking
# vLLM which ones it has, instead of hardcoding a guess — and the reason
# `gx10-check.sh` exists to prove the server can do the three things the app
# needs before anybody trusts it.
set -uo pipefail

MODEL_DIR="${MODEL_DIR:-$HOME/models/Qwen3.8-27B-NVFP4}"
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.8-27B-NVFP4}"
# The name the app asks for. Kept stable across checkpoint changes on purpose:
# ARCHITECTURE §17.1, EndpointRegistry and the verification log all name this,
# and re-quantising the weights is not a reason to edit three documents.
SERVED_NAME="${SERVED_NAME:-TeichAI/Qwen3.8-27B-Fable-Distill}"
PORT="${PORT:-8000}"

command -v vllm >/dev/null || { echo "✗ vllm not on PATH"; exit 1; }

# ── the weights ──────────────────────────────────────────────
# NVFP4 rather than bfloat16, and the difference is not a preference:
# 27B at bf16 is ~54 GB read per generated token, and this machine's memory
# bandwidth (~273 GB/s) caps that at ~5 tokens/second. Measured: 4.7. The
# NVFP4 checkpoint measured 11.8 on the same box (docs/VERIFICATION_LOG.md
# E.19, E.20). It is a hardware ceiling, not a tuning problem.
if [ ! -d "$MODEL_DIR" ]; then
  echo "── downloading $MODEL_REPO → $MODEL_DIR"
  hf download "$MODEL_REPO" --local-dir "$MODEL_DIR" || {
    echo "✗ download failed"; exit 1; }
fi

# ── parser names, asked rather than assumed ──────────────────
# The names differ between vLLM versions and between model families, and both
# outages above were a wrong flag value. So: read what this build offers, take
# the first from a preference list, and refuse to start if none match — a
# server that comes up without tool calling is worse than one that does not
# come up, because it looks fine.
HELP="$(vllm serve --help 2>&1)"

pick() {          # pick <flag-name> <candidate>...
  local flag="$1"; shift
  for name in "$@"; do
    # Word-boundary match: `qwen3` must not select `qwen3_xml` by accident,
    # and vice versa.
    if grep -qE "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" <<<"$HELP"; then
      echo "$name"; return 0
    fi
  done
  echo "✗ none of [$*] is a valid $flag on this vLLM build" >&2
  echo "   what it offers:" >&2
  grep -A8 -- "--$flag" <<<"$HELP" | sed 's/^/     /' >&2
  return 1
}

# Qwen3 writes tool calls as XML (`<function=name><parameter=x>`), NOT as the
# JSON that the `hermes` parser expects. Measured on this exact checkpoint.
TOOL_PARSER="$(pick tool-call-parser qwen3_xml qwen3_coder hermes)" || exit 1
# The model closes its scratchpad with `</think>` and never opens one — the
# chat template supplies the opening tag. Parsers for that pattern:
REASON_PARSER="$(pick reasoning-parser qwen3 deepseek_r1 qwen3_xml)" || exit 1

echo "── tool-call-parser : $TOOL_PARSER"
echo "── reasoning-parser : $REASON_PARSER"
echo "── serving as       : $SERVED_NAME  (port $PORT)"
echo

# `--dtype` is deliberately NOT set. On a quantised checkpoint vLLM reads the
# compute dtype from `quantization_config`; forcing bfloat16 dequantises the
# weights back to 54 GB and throws away the entire reason for using NVFP4.
#
# `--quantization` is deliberately NOT set either — 0.27.x detects it from the
# checkpoint, and naming the wrong scheme fails at load time.
exec vllm serve "$MODEL_DIR" \
  --served-model-name "$SERVED_NAME" \
  --trust-remote-code \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.90 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --max-num-seqs 256 \
  --port "$PORT" \
  --enable-auto-tool-choice \
  --tool-call-parser "$TOOL_PARSER" \
  --reasoning-parser "$REASON_PARSER"
