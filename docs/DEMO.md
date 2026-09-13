# Three-minute sample walkthrough

This is a reproducible tour of the native app, using committed sanitized data.
It is not a live inference recording or a performance claim about your Mac.

## Launch

Follow the [README setup](../README.md#run-the-demo), then run `make replay`.
This builds the app and opens `Resources/Samples/demo-session` in Analysis.
Alternatively, launch an existing Loupe app and select **Open sample session**.
No adapter, model, API key, or privileged helper is needed.

![Overview and sample entry point](media/overview.png)

## 0:00–0:45 — Read the trace

![Analysis with correlated phases and system telemetry](media/analysis.png)

Check the header: **20 samples**, **16 events**, **9.5 s**, acquisition loss
**unknown**, replay parser **0**, thermal **nominal → fair**.

Orange phase segments are prefill; blue segments are decode. Compare their
positions with memory/swap, GPU utilization, and power below. GPU and package
power are system-wide signals; they are not power measurements for one process.
The replay contains those channels even when the live helper is unavailable.

`unknown` is intentional: the bundled sample is historical protocol v1 and has
no terminal producer accounting. Zero parser drops only means the stored lines
parsed cleanly; it does not prove the original acquisition was lossless.

## 0:45–1:30 — Scrub across lanes

Drag across a chart, or choose **Start scrubber**, and inspect the shared
readout. Move from the first request to the second. The cursor aligns lanes
on one time axis while preserving each signal's units. Scroll down to the
observed process RSS and CPU lanes; CPU percentage can exceed 100% when a
process uses more than one core.

## 1:30–2:15 — Inspect requests and their events

![Request metrics and the event table](media/requests.png)

Scroll to **Requests (2)** and the events beneath it. Expected fixture values:

| Request | Prompt tokens | Output tokens | TTFT | Decode |
|---|---:|---:|---:|---:|
| q-1 | 96 | 48 | 450.0 ms | 19.8 tok/s |
| q-2 | 256 | 64 | 850.0 ms | 19.7 tok/s |

For q-1, request start is 3.00 s and the first positive output tick is 3.45 s
in the raw event clock: TTFT is 450 ms. Prefill ends at 3.38 s, so it is not
the TTFT endpoint. The UI timeline subtracts the session origin of 1.00 s.
These values describe the fixture, not a newly measured benchmark.

## 2:15–3:00 — Export inspectable evidence

Use the toolbar's **Export evidence JSON** (`{}`) and **Export evidence CSV**
buttons. Save each to a temporary folder and compare their source filenames,
SHA-256 hashes, counts, duration, and loss fields. Both exports should describe
the same loaded session. Keep the original session files beside the exports
when handing evidence to another engineer.

To independently check the bundled inputs from the repository root:

```bash
.venv/bin/python scripts/validate-sample.py
shasum -a 256 Resources/Samples/demo-session.ndjson Resources/Samples/demo-session.system.ndjson
```

## Next: a real recording

Follow the [recording quickstart](RECORDING_QUICKSTART.md) for MLX or llama.cpp,
then stop the session, reopen it from **History**, and export its evidence.
Current recordings use protocol v3; do not regenerate the historical demo just
to make its acquisition-loss label say zero.

The screenshots and this walkthrough cover sample replay. They do not certify
live adapter behavior, helper installation, export dialogs, or performance on
a particular machine. See [validation evidence](ENGINEERING_REVIEW.md#validation-evidence)
and [screenshot provenance](media/README.md).
