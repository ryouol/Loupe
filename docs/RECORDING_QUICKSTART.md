# Recording quickstart

This guide records one real local request without placing prompt text in a
process argument. Loupe is macOS 15+ / Apple Silicon software. Use full Xcode
16 or newer, not Command Line Tools alone.

## Build and open Loupe

Install Xcode from Apple, select it, then install the command-line project
tools and the locked MLX environment:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install uv xcodegen
make bootstrap-mlx
xcodebuild build -scheme Loupe -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
open DerivedData/Build/Products/Debug/Loupe.app
```

The lock currently resolves Python 3.12 with `mlx==0.32.2` and
`mlx-lm==0.31.3`. Treat `uv.lock` as the authority instead of installing
unlocked packages. Capture the actual tools used on the recording machine:

```bash
swift --version
xcodebuild -version
.venv/bin/python --version
.venv/bin/python - <<'PY'
from importlib.metadata import version
for package in ("loupe-mlx", "mlx", "mlx-lm"):
    print(package, version(package))
PY
```

In Loupe, choose **Record**, then **Start Recording**. The state changes from
preparing to **Waiting for adapter**. Copy the two values shown by the app into
the same terminal that will run an adapter:

```bash
export LOUPE_SOCKET_PATH='/paste/the/path/from/Loupe/adapter.sock'
export LOUPE_RUN_ID='paste-the-run-id-from-Loupe'
```

Do not invent or reuse values from an older session.

## MLX recording

Run the following from the repository after `make bootstrap-mlx`. Substitute
an exact model identifier and revision appropriate for the work being tested.
The prompt exists only in Python memory; Loupe's event protocol has no prompt
or generated-text field.

```bash
.venv/bin/python - <<'PY'
from loupe_mlx import LoupeInstrument

MODEL = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
PROMPT = "Explain the difference between prefill and decode in one sentence."

loupe = LoupeInstrument()
try:
    model, tokenizer = loupe.load(MODEL)
    for response in loupe.stream_generate(
        model, tokenizer, prompt=PROMPT, max_tokens=64
    ):
        print(response.text, end="", flush=True)
finally:
    loupe.close()
print()
PY
```

MLX does not expose a direct KV allocation counter through this adapter. Its
decode events label allocator growth as `allocator_delta_proxy`; Loupe records
that as typed memory evidence but never uses it for a KV-dominated finding. Record
the exact model revision and artifact hash alongside any customer-facing
claim; a session source hash is not a model-artifact hash.

## llama.cpp recording

Install a current `llama-server` build, retain its version/build output, and
hash the exact GGUF:

```bash
brew install llama.cpp
llama-server --version 2>&1 | tee llama-runtime-version.txt
shasum -a 256 /absolute/path/model.gguf | tee model.gguf.sha256
llama-server -m /absolute/path/model.gguf \
  --host 127.0.0.1 --port 8080 --metrics
```

Leave the server running. In another terminal, export the Loupe socket/run ID
shown by the waiting recording, then run the adapter. Replace all four KV
numbers with the GGUF architecture's actual layer count, KV-head count,
per-head dimension, and cache bytes per element. They are required: Loupe
labels the resulting value `architecture_modeled_kv`, so guessed geometry
would create misleading evidence. Packed sub-byte cache formats cannot be
represented by the integer bytes-per-element flag; do not use this modeled-KV
path for one of those formats.

```bash
export LOUPE_SOCKET_PATH='/paste/the/path/from/Loupe/adapter.sock'
export LOUPE_RUN_ID='paste-the-run-id-from-Loupe'

swift run loupe-llamacpp \
  --server http://127.0.0.1:8080 \
  --max-tokens 64 \
  --kv-layers 24 \
  --kv-heads 2 \
  --kv-head-dim 64 \
  --kv-bytes-per-element 2 \
  --prompt-stdin <<'PROMPT'
Explain the difference between prefill and decode in one sentence.
PROMPT
```

The numeric host must exactly match the listener (`127.0.0.1` versus `::1`).
Loupe resolves the same-user PID by address family, address, port, and listen
state. It disables redirects and configured proxies before sending the local
HTTP request.

## Finish and verify

After a valid `session_start`, the UI moves to **Recording**. Stop the run in
Loupe after the adapter exits and its transport summary has drained. Open the
session from **History**, scrub the CPU/RSS, memory/swap, GPU utilization,
GPU power, and package-power lanes that are actually available, then export
both JSON and CSV evidence. Both formats include source filenames and SHA-256,
counts, duration, thermal states, replay-parser drops, and acquisition-loss
status. TTFT is request start to the first positive output tick.

Local unsigned builds deliberately do not install the privileged helper. CPU,
RSS, memory, swap, and thermal data still work; unavailable GPU/power lanes are
hidden instead of shown as zero.

## Recovery

- If Loupe remains **Waiting for adapter**, confirm the two exported values
  came from the active recording and that the socket exists. Do not start a
  second model operation on one `LoupeInstrument`; it is intentionally
  single-flight.
- If an adapter disconnects, Loupe keeps the session and shows a disconnected
  state. Restart it with the same active run ID to reconnect. New adapter
  instances use non-colliding request IDs.
- If the app, adapter, or helper exits without a terminal loss summary, stop
  and retain the session, but expect acquisition loss to display/export as
  `unknown` (possibly with a lower bound), not zero.
- For llama.cpp PID-resolution failures, verify the server is listening on the
  exact numeric host/port passed to `--server` and is owned by the logged-in
  user. For MLX import failures, rerun `make bootstrap-mlx` rather than
  installing packages outside the lock.
- Prompts are absent from event files and adapter argv, but the model runtime,
  shell input, and generated output remain sensitive. Do not publish terminal
  logs or raw runtime artifacts without reviewing them.

The workspace's launch-readiness evidence does not claim a live MLX run,
hardware benchmark, signed helper, notarized DMG, or customer-machine test.
Complete those external gates before using this guide as release evidence.
