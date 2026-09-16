# Real local MLX receipts

Authoritative result: [`summary.json`](summary.json), derived from
`verified/client.json` and the actual Swift replay/export path. Human explanation:
[case study](../../docs/MLX_CASE_STUDY.md). [Demo](../../docs/MLX_DEMO.md).

`recordings.tar.gz` contains unmodified raw event/client/telemetry receipts and
their exports; `SHA256.json` hashes each archived file and the archive. Extract
into an empty scratch directory as shown in the demo. No model weights are
included; manifests identify the exact Hub revision and hash every model file.

| Archive directory | Meaning |
|---|---|
| `baseline` | Exploratory pre-tokenization intervention. Source adapter from `cc5d120`; compiler activity overlapped this run. Retained negative/uncertain result, not a speedup claim. Includes the first interrupted-replay probe and its older schema-3 export. |
| `bpe-cache` | First vocabulary-map intervention, old reconstructed phase boundaries. Supplementary native host sample. Maximum client/event TTFT discrepancy 2.680 ms fails the later strict 2 ms acceptance check; retained, not authoritative. |
| `verified` | Corrected callback-based adapter, all four workload conditions, five alternating pairs each, one warmup, one deliberate cancellation. This directory supplies the published table and metric-boundary checks. |
| `collection-off` | Five pairs of the slowest condition through direct MLX calls; Loupe events, native telemetry, and Python sampling disabled. |

All captured runs used the pinned model and locked runtime. `baseline_commit`
identifies the upstream starting point; `verified` additionally uses the adapter
patch in this change. The harness evolved during the investigation (including
the later collection-off option); reproducing the published result uses the
final script's default collection-on behavior with `--experiment bpe`. New runs
also record source-file hashes. Existing receipts are retained rather than
rewritten to imply that later metadata existed at capture time.

`collection-control.json` compares collection-on/off blocks. It is not a precise
overhead bound because blocks ran at different times. All verified thermal
samples were nominal. Memory-pressure values and system swap are recorded,
without claiming that the model caused either. Python stacks and native host
samples provide host-side evidence only; no GPU-kernel or Instruments trace was
captured. Full Xcode was unavailable locally.

The file-sink capture has no authoritative terminal recorder acquisition
summary. Zero parser drops therefore **does not** mean zero acquisition loss.
The export reports acquisition loss as unknown. The preserved failed/missing
input probes and explicit request outcomes prevent cancellation or truncation
from masquerading as a completed generation.

Serving import has synthetic contract tests, but there is no real Unrender
vLLM artifact in this evidence set. Do not present those tests as a real remote
serving capture.
