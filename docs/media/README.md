# Screenshot provenance

These are unretouched native Loupe screenshots, not generated mockups.
Captured or supplied September 12, 2026. No screenshot represents a new live
inference benchmark.

| File | Origin | What it demonstrates |
|---|---|---|
| `analysis.png` | Screenshot supplied by the repository owner for this review package; exact running build not independently identified | Bundled `demo-session`, phase alignment, system telemetry, separate acquisition/parser counts |
| `overview.png` | Captured from the app downloaded from [CI run 33529158114](https://github.com/ryouol/Loupe/actions/runs/33529158114), source `cc5d120`; artifact SHA-256 checked before opening | Real overview screen, sample entry point, and visible helper warning in this unsigned build |
| `requests.png` | Captured from the owner's already-running local Loupe window; exact build not independently identified | The bundled sample's request metrics and event table |

The sample is `Resources/Samples/demo-session`: 16 historical v1 events,
20 sanitized telemetry rows, and a synthetic PID. Chart data describes those
files, not live activity on the capture host. Overview hardware details describe
the capture host only. Window appearance depends on macOS and window focus.

## Refresh the images

1. Build the source revision being reviewed on full Xcode and record its SHA.
2. Open only the sanitized bundled sample (`make replay` or **Open sample session**).
3. Capture the app window at roughly 1040 × 700: overview, the top of Analysis,
   then the request/event tables farther down.
4. Exclude desktop contents, private session names, local paths, prompts, and
   generated text. Keep warnings and unavailable-data labels intact.
5. Replace the PNGs, inspect them at README size, and update this provenance.

For a screen recording, follow [DEMO.md](../DEMO.md) and label it as bundled
sample replay. A screenshot sequence should be called a screenshot tour, not
presented as a live interaction recording.
