#!/usr/bin/env bash
# Records real llama-server HTTP responses into fixtures/llamacpp/ so the
# adapter tests never need a live server. Golden files — never regenerate
# casually; a schema change in llama.cpp deserves a deliberate re-record.
set -euo pipefail

MODEL="${LOUPE_GGUF_MODEL:-$HOME/Library/Caches/loupe-models/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
PORT="${LOUPE_LLAMA_PORT:-18080}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/fixtures/llamacpp"

[[ -f "$MODEL" ]] || { echo "no GGUF at $MODEL" >&2; exit 1; }
command -v llama-server >/dev/null || { echo "llama-server not on PATH" >&2; exit 1; }
mkdir -p "$OUT"

llama-server -m "$MODEL" --port "$PORT" --metrics --log-disable >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

echo "waiting for llama-server (pid $SERVER_PID) on :$PORT ..."
for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || { echo "server never became healthy" >&2; exit 1; }

curl -sf "http://127.0.0.1:$PORT/props" > "$OUT/props.json"
curl -sf "http://127.0.0.1:$PORT/metrics" > "$OUT/metrics-idle.txt"

curl -sf -X POST "http://127.0.0.1:$PORT/completion" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Explain the difference between prefill and decode in one sentence.","n_predict":32,"stream":true}' \
    > "$OUT/completion-stream.txt"

curl -sf "http://127.0.0.1:$PORT/metrics" > "$OUT/metrics-after.txt"

kill "$SERVER_PID" 2>/dev/null || true
trap - EXIT

echo "recorded:"
wc -l "$OUT"/* | sed 's/^/  /'