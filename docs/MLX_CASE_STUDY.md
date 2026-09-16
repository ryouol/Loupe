# A repeated BPE vocabulary build delayed local MLX requests

September 16, 2026 · profiling milestone, not a signed application release.

**Finding.** On Roy's M1 Pro / 16 GiB Mac, Loupe exposed approximately 100 ms
of avoidable host setup before each request's prefill. Python stack sampling
located repeated `BPEStreamingDetokenizer.__init__ → tokenizer.vocab → get_vocab`
calls. MLX-LM 0.31.3 creates a new detokenizer for each stream; its constructor
materializes the vocabulary twice and rebuilds the ID-to-text map. Source
inspection and a controlled intervention establish this host cost. Python
samples do not establish GPU kernel time.

**Controlled change.** Build one immutable BPE vocabulary map after model load;
copy/reset the detokenizer for each request so text and token buffers remain
independent. This is an opt-in helper, restricted to the tested MLX-LM version
and BPE detokenizer. Rebuild it if the vocabulary changes. No precision, model,
decoding, prompt, or output-limit change was made. Cache construction cost
128 ms once; the table measures subsequent requests, not cold startup.

| Prompt / output tokens | Baseline median TTFT | Cached median TTFT | Baseline median total | Cached median total |
|---|---:|---:|---:|---:|
| 128 / 32 | 138.2 ms | 46.3 ms | 275.2 ms | 176.0 ms |
| 128 / 128 | 146.0 ms | 45.3 ms | 698.8 ms | 571.2 ms |
| 8,192 / 32 | 2,654.7 ms | 2,557.6 ms | 2,894.5 ms | 2,790.8 ms |
| 8,192 / 128 | 2,680.0 ms | 2,551.1 ms | 3,623.0 ms | 3,487.1 ms |

Five paired repetitions per condition, alternating order, one excluded warmup;
greedy decoding, seed 42, Qwen2.5-0.5B-Instruct-4bit revision
`a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`, MLX 0.32.2 / MLX-LM 0.31.3.
All 20 paired outputs matched token-for-token and by text SHA-256. The slowest
condition improved **3.75% in median total latency**; its observed setup before
runtime prefill fell from 116.1 to 12.6 ms. Long-prompt processing still dominates.
Fresh-process model loading took 480 ms with an already downloaded snapshot;
this is not a cold-disk or download benchmark. Raw repeats, model-file hashes,
Python/runtime versions, samples, and client receipts are retained in
[`investigations/mlx-2026-09-16`](../investigations/mlx-2026-09-16).

**Metric correction.** The old adapter placed `prefill_end` at request start
plus MLX's prompt duration. That excluded detokenizer setup from prefill but
silently included it in the reconstructed decode interval. It also confused
MLX's prompt timer (which includes first-token evaluation) with a phase boundary.
The adapter now observes the runtime callback after evaluation of all but the
final prompt token. Decode includes the final prompt-token forward pass and
the first generated token through the last response. This is an explicit host
observation, not exclusive GPU time. Runtime paths without that callback leave
decode duration unavailable. Independent `perf_counter_ns` receipts agreed with
Loupe's TTFT within **0.282 ms**, prefill boundary within **0.694 ms**, and decode
duration within **0.519 ms** over all 42 recorded requests. Client TTFT here means
first generated token receipt, including tokens whose streaming text is empty.

**Reliability and limits.** Swift replay accepted all 3,371 events with zero
parser drops; JSON/CSV include hashes and explicit cancellation outcomes. A real
request was closed after eight responses. A separately truncated copy preserves
an incomplete outcome and omits its latency/throughput metrics; missing telemetry
fails export. Acquisition loss remains **unknown**, not zero: the file recorder
has no final acquisition summary. Thermal state was nominal throughout; memory
pressure was normal/warning (raw values 1/2), with roughly 4.01–4.05 GiB of
system swap already present. Do not attribute this system-wide swap to the model.
These are small, sequential local samples, not serving throughput or tail SLOs.

**Retained negative experiment.** Pre-tokenizing the repeated prompt changed
the slowest condition's median total latency by only about 20 ms (0.56%) in the
initial sweep, with mixed results elsewhere. That exploratory run overlapped
compilation and cannot support a speedup claim. The subsequent vocabulary-cache
runs were performed after compilation finished. A native host `sample` trace is
supplementary CPU/wait evidence only. Full Xcode and Instruments are absent;
local Swift builds/replay passed, but local XCTest, Swift Instruments analysis,
GPU kernel attribution, signing, and notarization are not claimed.

Reproduce and present with the [three-minute demo](MLX_DEMO.md).

**Collection control.** With Loupe events, telemetry, and Python sampling disabled,
five further pairs at 8,192 / 128 measured 3,596.7 ms baseline versus 3,489.7 ms
cached (2.97% median reduction), with matching output hashes. Collection-on
medians differed by +0.73% for baseline and −0.08% for cached. These separate
blocks include system drift and do not establish a precise overhead bound.
The exploratory `bpe-cache` capture failed the strict 2 ms TTFT agreement check
(maximum 2.680 ms); its receipts are retained, but the corrected `verified`
capture supplies the reported boundary and performance claims.
