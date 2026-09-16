# Real MLX profiling and remote-serving imports

The completed local investigation is [prefill chunk sizing](2026-09-16-prefill.md). It includes real model events, system telemetry, independent client timing, a host profile and native replay exports. The serving importer is implemented and fixture-tested; **no live vLLM or Unrender capture has been measured yet**.

## Reproduce the local investigation

Use the repository's locked environment (`make bootstrap-mlx` with full Xcode, or `UV_PROJECT_ENVIRONMENT="$PWD/.venv" uv sync --project adapters/loupe-mlx --locked --extra dev --extra mlx` for CLI work). Build `swift build --product loupe-record` and `swift build --product loupe-report`. The CLI products build with Command Line Tools; the full test suite requires XCTest from Xcode.

Download the public model `mlx-community/Qwen2.5-0.5B-Instruct-4bit` at revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3` using Hugging Face's `snapshot_download`. Pass the resulting local directory as MODEL_PATH. No model weights belong in this repository.

```bash
.venv/bin/python -m loupe_mlx.investigate \
  --model "$MODEL_PATH" \
  --revision a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3 \
  --out benchmarks/new-investigation &
MODEL_PID=$!
.build/debug/loupe-record --pid "$MODEL_PID" --duration 180 \
  --out benchmarks/new-investigation.system.ndjson &
RECORDER_PID=$!
wait "$MODEL_PID"
wait "$RECORDER_PID"
.venv/bin/python scripts/summarize-investigation.py benchmarks/new-investigation
.build/debug/loupe-report \
  --events benchmarks/new-investigation/session.ndjson \
  --system benchmarks/new-investigation.system.ndjson \
  --out benchmarks/new-investigation/native
```

Run on a quiet machine without another load test. The recorder exits when the model process disappears. It uses unprivileged live telemetry; missing channels remain missing. The runner refuses an existing output directory, hashes model/configuration/source files, fixes greedy sampling, verifies actual prompt token counts, and alternates 64/512-token prefill steps over three repeats. Model load and warmups are separate from measured requests. cProfile runs are separate too; its timings are not used in performance deltas.

`client.json` and `client.csv` contain independent boundaries and output-token hashes; `session.ndjson` uses the existing v3 protocol; `requests.json` retains cancellation/incomplete states. `loupe-report` uses LoupeCore's decoder and completion metrics, writes source hashes, parser-drop counts, terminal reasons and JSON/CSV. Acquisition losses must still be checked using sequence and terminal-summary evidence. It does not convert parser success into proof of zero acquisition loss.

## Three-minute demo

1. Open the recorded `session.ndjson` in Loupe with `session.system.ndjson` alongside it. Or use `loupe-report` for headless native replay.
2. Compare the short and long prompts using `client.csv` and `summary.json`; show that a larger prefill step helps the long prompts but is not uniformly better.
3. Show the raw cancellation terminal event and its exclusion from the native completed-request export.
4. Show the host profile, exact model/runtime provenance and token-hash equality. Explain why this is a local workload experiment, not a serving throughput or GPU-kernel optimization claim.

## Remote serving contract

```bash
.venv/bin/python -m loupe_mlx.import_serving \
  --input path/to/serving-capture.json --out benchmarks/new-serving-import
```

Input is explicitly `loupe-serving-capture/v1`, not arbitrary `vllm bench serve` JSON. A producer such as a future Unrender benchmark must export this normalized contract:

```json
{
  "schema": "loupe-serving-capture/v1",
  "duration_ms": 1000,
  "provenance": {
    "runtime": "vllm",
    "runtime_version": "PINNED_VERSION",
    "model_revision": "PINNED_REVISION",
    "hardware": "GPU_TYPE_AND_MEMORY",
    "workload_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "requests": [
    {"id": "example", "status": "ok", "start_ms": 0,
     "first_token_ms": 100, "end_ms": 500, "output_tokens": 20}
  ],
  "server_aggregate_metrics": {"kv_cache_usage_ratio": 0.5}
}
```

The example is synthetic and establishes no performance result. Times share one client monotonic origin; `duration_ms` spans the whole run including failed requests and drain. First-token timing excludes empty streaming metadata. Token counts come from the runtime/tokenizer, not chunk counts. Valid statuses: `ok`, `error`, `timeout`, `cancelled`, `rejected`; failures remain in the report. Per-request decode rate and prefill time remain unavailable because client start/first/end boundaries cannot establish them. Server metrics retain their names/units and stay aggregate; they never become local GPU samples or per-request cache measurements. Small samples do not get a p99. This CLI produces separate JSON/CSV serving reports; the local native timeline/comparison format is intentionally not synthesized from incompatible clocks.

The importer bounds input to 16 MiB, checks identity/provenance/timing/token constraints, hashes the source and prevents overwriting reports. Tests cover invalid timing, missing provenance, duplicate IDs, failed requests, and CSV formula protection.
