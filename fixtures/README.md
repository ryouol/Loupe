# Fixtures

Fixtures are offline test evidence and are never regenerated merely to silence
a failing test.

## Bundled demo

`Resources/Samples/demo-session` is the shipping zero-cost demo: 16 historical
protocol-v1 events and 20 sanitized telemetry rows. Its embedded adapter
version string is fixture metadata from before protocol negotiation; it does
not mean the current 0.2.0 adapter emits v1.
It includes clock sync, two complete requests, GPU/power data, swap growth, and
a thermal-state change. It contains no prompt or generated text and uses a
synthetic PID. Swift/Python checks require every event to decode with zero
drops.

## Baseline session

`fixtures/baseline-session` remains the large historical performance fixture:
105 requests, 21,318 events, and 739 samples. It is useful for downsampling and
timeline stress tests but is not bundled because it is large and predates the
current adapter/telemetry coverage.

`benchmark-baseline.report.json` is also a historical format-v1 fixture. It
lacks the artifact, dependency-lock, and runtime provenance required by the
current comparison gate, so the app intentionally treats it as view-only. Do
not publish its values or upgrade it by inventing provenance.

Record a deliberate new fixture with:

```bash
make record-fixture NAME=<name> DURATION=<seconds>
```

Review the diff for model/runtime identity, protocol version, line counts,
thermal coverage, accidental prompt/error leakage, and reproducibility before
committing it.

The committed llama.cpp HTTP fixtures retain only the response shape needed by
tests; local model paths and the captured prompt are replaced with sanitized
placeholders.
