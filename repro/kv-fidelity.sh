#!/usr/bin/env bash
# Reproduces F-1: q8_0 KV cache output is byte-identical to f16 on this setup.
#
# Runs the same greedy completion twice, once with f16 KV and once with q8_0 KV,
# then diffs the two outputs. Greedy decoding with a fixed seed is what makes the
# comparison meaningful: any divergence is the cache, not sampling.
#
# usage: ./kv-fidelity.sh /path/to/model.gguf [n_predict]
set -euo pipefail

MODEL="${1:?usage: kv-fidelity.sh /path/to/model.gguf [n_predict]}"
NPRED="${2:-256}"
LLAMA_CLI="${LLAMA_CLI:-llama-cli}"
PROMPT="${PROMPT:-Explain how a mixture-of-experts transformer routes tokens, step by step.}"
SEED="${SEED:-1234}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

run_one () {
    local label="$1" ctk="$2" ctv="$3"
    echo "  running $label ..." >&2
    "$LLAMA_CLI" \
        --model "$MODEL" \
        --prompt "$PROMPT" \
        --n-predict "$NPRED" \
        --temp 0 \
        --seed "$SEED" \
        --cache-type-k "$ctk" \
        --cache-type-v "$ctv" \
        --flash-attn \
        --no-display-prompt \
        > "$OUT/$label.txt" 2>"$OUT/$label.err" \
      || { echo "  FAILED. stderr tail:" >&2; tail -5 "$OUT/$label.err" >&2; exit 1; }
}

echo "KV cache fidelity: f16 vs q8_0"
echo "model      : $MODEL"
echo "n_predict  : $NPRED   seed: $SEED   sampling: greedy (temp 0)"
echo

run_one f16  f16  f16
run_one q8_0 q8_0 q8_0

echo
if diff -q "$OUT/f16.txt" "$OUT/q8_0.txt" >/dev/null; then
    echo "RESULT: byte-identical. F-1 reproduces."
    echo "        $(wc -c < "$OUT/f16.txt") bytes, identical under both cache types."
else
    echo "RESULT: outputs diverge. F-1 does NOT reproduce on this build/model."
    echo
    echo "First divergence:"
    diff "$OUT/f16.txt" "$OUT/q8_0.txt" | head -20
    echo
    echo "This is a legitimate negative. The finding was measured on one model"
    echo "and one build; it is not a general claim about q8_0."
fi
