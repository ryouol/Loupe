#!/usr/bin/env bash
# Records a fixture pair: <name>.ndjson (protocol-v1 events from a real
# mlx-lm session) + <name>.system.ndjson (unprivileged system samples).
# No root required. Fixtures are golden files — never regenerate casually.
set -euo pipefail

NAME="${1:?usage: record-fixture.sh <name> [duration-seconds]}"
DURATION="${2:-60}"
MODEL="${LOUPE_FIXTURE_MODEL:-mlx-community/Qwen2.5-0.5B-Instruct-4bit}"

if [[ ! "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "fixture name must be a simple 1-64 character filename stem" >&2
    exit 2
fi
if [[ ! "$DURATION" =~ ^[0-9]{1,4}$ ]]; then
    echo "duration must be an integer from 1 to 3300 seconds" >&2
    exit 2
fi
DURATION=$((10#$DURATION))
if ((DURATION < 1 || DURATION > 3300)); then
    echo "duration must be an integer from 1 to 3300 seconds" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PYTHON=".venv/bin/python"
if [[ ! -x "$PYTHON" ]] || ! "$PYTHON" -c "import mlx_lm" 2>/dev/null; then
    echo "mlx-lm not available in the venv; run 'make bootstrap-mlx' first." >&2
    exit 1
fi

swift build --product loupe-record
RECORDER="$(swift build --show-bin-path)/loupe-record"

mkdir -p fixtures
EVENTS="fixtures/$NAME.ndjson"
SYSTEM="fixtures/$NAME.system.ndjson"

echo "Recording '$NAME' for ${DURATION}s with $MODEL ..."
"$PYTHON" -m loupe_mlx.record --model "$MODEL" --out "$EVENTS" --duration "$DURATION" &
PY_PID=$!
trap 'kill "$PY_PID" 2>/dev/null || true' EXIT

# The recorder follows the generator PID and stops on its own when the
# generator exits; the generous deadline only bounds a hung generator.
"$RECORDER" --out "$SYSTEM" --pid "$PY_PID" --duration $((DURATION + 300)) &
REC_PID=$!
trap 'kill "$PY_PID" "$REC_PID" 2>/dev/null || true' EXIT

wait "$PY_PID"
wait "$REC_PID"
trap - EXIT

# A fixture that doesn't decode cleanly must never be committed.
"$PYTHON" - "$EVENTS" <<'PYEOF'
import sys
from loupe_mlx.events import decode_line
lines = open(sys.argv[1], "rb").read().splitlines()
for line in lines:
    decode_line(line)
print(f"validated {len(lines)} event lines, zero drops")
PYEOF

echo "events:  $EVENTS  ($(wc -l < "$EVENTS" | tr -d ' ') lines)"
echo "system:  $SYSTEM  ($(wc -l < "$SYSTEM" | tr -d ' ') lines)"
echo "Thermal states seen: $(grep -o '"thermalState":"[a-z]*"' "$SYSTEM" | sort -u | tr '\n' ' ')"
