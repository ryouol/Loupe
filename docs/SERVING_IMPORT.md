# Offline serving-result import

The local MLX case is documented in [MLX_CASE_STUDY.md](MLX_CASE_STUDY.md).
This follow-on CLI imports saved vLLM benchmark client timings and a saved
Prometheus runtime snapshot into separate JSON/CSV serving evidence. It performs
no network calls and does not synthesize local Mac telemetry or an aligned timeline.

**Current validation:** synthetic contract tests, clearly labeled in the test
fixture. No vLLM client/runtime artifacts were present in the inspected Unrender
checkout on September 16, 2026. A real Unrender import remains pending those
source files; this is not a claim that a serving benchmark was run or imported.

Supported client format: vLLM 0.12 `bench serve --save-result --save-detailed`
arrays (`input_lens`, `output_lens`, `ttfts`, `itls`, `errors`, `completed`). The
format is explicitly pinned using the [upstream source](https://github.com/vllm-project/vllm/blob/v0.12.0/vllm/benchmarks/serve.py).
Aggregate-only reports and mismatched arrays fail instead of manufacturing
requests. Other Unrender artifact schemas require an explicit mapping after
examining a real artifact.

Supply an operator provenance file:

```json
{
  "format": "vllm-bench-serve-detailed-v0.12",
  "run_id": "replace-with-real-run-id",
  "client_host": "replace-with-client-host",
  "server_host": "replace-with-serving-host",
  "runtime_version": "replace-with-exact-version",
  "model_revision": "replace-with-pinned-revision",
  "metrics_captured_at": "replace-with-actual-snapshot-time"
}
```

```bash
.venv/bin/python -m loupe_mlx.serving_import \
  --client /path/to/vllm-detailed-result.json \
  --metrics /path/to/saved-metrics.prom \
  --provenance /path/to/provenance.json \
  --out /path/to/new-serving-evidence-directory
```

Both exports retain source SHA-256 and explicit client/server scope. Request
identity is the array index, not an invented server request ID. Failed requests
retain their status; zero placeholders and unavailable latency are null. The
source format lacks per-request end-to-end latency, so the importer leaves it
unavailable rather than adding streamed-chunk gaps. Text and raw error messages
are omitted. Aggregate runtime counters and histograms remain a **snapshot**;
they can include traffic outside the run. Association with the client run and
host labels is operator supplied and not independently verified.

Server prefill/decode durations are null for every request. Histograms cannot
supply those boundaries. Remote GPU/cache metrics remain attached to the
declared serving host; no local-Mac memory value is inferred. Client TTFT is a
network/client observation, not the local adapter's prefill interval. The
[vLLM metric documentation](https://github.com/vllm-project/vllm/blob/main/docs/design/metrics.md)
describes runtime aggregates; the importer preserves their original names and
does not derive per-request attributions from them. Live collection is deferred
until an actual investigation shows a need for it.
