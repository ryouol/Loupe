# Three-minute real-capture demo

Prerequisite: use the repository's Python 3.12 environment and build
`swift build --product loupe-export`. The demo replays an actual capture without
downloading a model or performing inference. Recorded source hashes stay visible.

**0:00–0:30 — State the question.** Open [the one-page case](MLX_CASE_STUDY.md).
“What did Loupe reveal? About 100 ms of repeated Python-host setup. What changed?
One immutable BPE vocabulary map is reused, with fresh text state per request.”

**0:30–1:15 — Replay and export.** Extract the retained receipts if needed:

```bash
mkdir -p .build/investigation
tar -xzf investigations/mlx-2026-09-16/recordings.tar.gz -C .build/investigation
.build/debug/loupe-export .build/investigation/verified/capture /tmp/loupe-real-evidence
```

Open the JSON and CSV. Show source hashes, 3,371 events, zero parser drops,
nominal thermal state, and the cancelled request outcome. Acquisition loss is
unknown. The CLI calls the same Swift replay model and evidence exporters as
the native UI. An existing Loupe app can open the extracted `capture.ndjson`;
the updated status column requires a build from this branch.

**1:15–2:00 — Show cause, not just correlation.** Open
`baseline/python-samples.folded` in the extracted archive; search `get_vocab`.
Follow the stack into MLX-LM's BPE detokenizer constructor. Compare the original
and cached tokenizer implementation in `loupe_mlx/bpe_cache.py`. Both use fresh
per-request state; only immutable vocabulary data is shared. Explain that
neither the Python samples nor the supplementary native host trace measures GPU
kernel duration. The preserved pre-tokenization experiment did not establish a
reliable improvement.

**2:00–2:40 — Verify outcomes and boundaries.** Run:

```bash
.venv/bin/python scripts/check-investigation.py .build/investigation/verified
```

Show the four paired conditions and identical output checks. The slowest
condition improves from 3,623 to 3,487 ms median over five repetitions. The
checker independently compares client clocks with Loupe events, verifies the real
cancellation already in the capture, truncates a copy to test incomplete data, and
checks that missing telemetry cannot silently become zero-valued evidence.

**2:40–3:00 — State scope.** “This is a tested local profiling milestone. It
identified and reduced a specific host-side cost. It does not establish GPU
kernel acceleration, remote serving throughput, a memory-pressure cause, or a
signed/notarized customer release.” Point to the receipt manifest and CI run.

For a new live experiment, choose a new output directory:

```bash
.venv/bin/python scripts/investigate-mlx.py \
  --model /absolute/path/to/the/pinned/model/snapshot \
  --out /tmp/loupe-new-investigation --recorder .build/debug/loupe-record \
  --experiment bpe
```

This records through the real MLX adapter's synchronous file sink and Loupe's
native unprivileged telemetry recorder. It does not assert verification of the
app's socket/SQLite acquisition path by this experiment.
