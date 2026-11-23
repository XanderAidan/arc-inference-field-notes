#!/usr/bin/env bash
# Reproduces F-3: aggregate throughput against --parallel slot count.
#
# For each slot count, starts llama-server, fires that many concurrent
# completions, and reports aggregate tokens per second measured as
# (total tokens generated) / (wall time for the whole batch).
#
# Aggregate throughput is NOT per-stream decode. Per-stream falls as slots rise.
# Comparing the two is the most common error when reading this result.
#
# usage: ./parallel-sweep.sh /path/to/model.gguf [slot counts...]
set -euo pipefail

MODEL="${1:?usage: parallel-sweep.sh /path/to/model.gguf [slots...]}"; shift || true
SLOTS=("${@:-2 4 8}")
[[ ${#SLOTS[@]} -eq 1 ]] && read -ra SLOTS <<< "${SLOTS[0]}"

LLAMA_SERVER="${LLAMA_SERVER:-llama-server}"
PORT="${PORT:-18080}"
CTX="${CTX:-65536}"
NPRED="${NPRED:-128}"
PROMPT="${PROMPT:-Write a short technical description of PCIe link training.}"

printf '%-10s %-14s %-16s %s\n' "slots" "ctx per slot" "wall time (s)" "aggregate tok/s"
printf '%-10s %-14s %-16s %s\n' "-----" "------------" "-------------" "---------------"

for n in "${SLOTS[@]}"; do
    "$LLAMA_SERVER" --model "$MODEL" --port "$PORT" \
        --ctx-size "$CTX" --parallel "$n" \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn \
        >/dev/null 2>&1 &
    server_pid=$!
    # shellcheck disable=SC2064
    trap "kill $server_pid 2>/dev/null || true" EXIT

    for _ in $(seq 60); do
        curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
        sleep 1
    done

    tmp=$(mktemp -d)
    start=$(date +%s.%N)
    for i in $(seq "$n"); do
        curl -fsS "http://127.0.0.1:$PORT/completion" \
            -H 'Content-Type: application/json' \
            -d "{\"prompt\":\"$PROMPT\",\"n_predict\":$NPRED,\"temperature\":0}" \
            > "$tmp/$i.json" 2>/dev/null &
    done
    wait
    end=$(date +%s.%N)

    total_tokens=$(cat "$tmp"/*.json 2>/dev/null \
        | grep -o '"tokens_predicted":[0-9]*' \
        | cut -d: -f2 | paste -sd+ - | bc 2>/dev/null || echo 0)
    wall=$(echo "$end - $start" | bc)
    agg=$(echo "scale=1; $total_tokens / $wall" | bc 2>/dev/null || echo "n/a")

    printf '%-10s %-14s %-16s %s\n' "$n" "$((CTX / n))" "$(printf '%.1f' "$wall")" "$agg"

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    trap - EXIT
    rm -rf "$tmp"
    sleep 2
done

echo
echo "Measured on the reference rig: 71 tok/s aggregate at 2 slots,"
echo "120 tok/s aggregate at 8 slots. Note the context-per-slot column:"
echo "throughput is bought with window size."
