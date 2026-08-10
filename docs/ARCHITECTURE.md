# Loupe — Product & Architecture Walkthrough

*A native macOS profiler for local AI inference on Apple Silicon.* Loupe
answers the question every local-LLM user eventually asks: **"why is it slow
right now?"** — by putting runtime-level inference events (model load,
prefill, decode, KV cache) and system telemetry (CPU, memory, swap, thermal,
GPU busy, package power) on one correlated timeline, then reading it for you
with evidence-backed findings.

## What the product does today (v0.1.0)

| Surface | What you get |
|---|---|
| **Session timeline** | Prefill/decode swimlanes per request above aligned telemetry lanes (memory/swap, GPU/power, process RSS), one shared x-axis, one scrubber, per-request TTFT and decode-rate table |
| **Findings** | Five rule-based annotations — thermal throttling, memory pressure, prefill queueing, KV-dominated footprint, GPU underutilization — each carrying the exact samples that triggered it, with jump-to-moment |
| **Benchmarks** | `make bench` runs YAML-specced context sweeps (warmup discarded, thermal cooldown gated between runs) → reports with p50/p95/σ, rendered as error-bar charts |
| **Comparison** | A/B two reports; mismatched specs (model, quantization, contexts, seed, chip, RAM…) render a blocking banner and **refuse** the headline delta; CSV/JSON export mirrors the refusal |
| **Runtimes** | MLX (in-process Python instrumentation, <1% measured overhead) and llama.cpp (external observer of llama-server via its own `timings`) |
| **Daemon** | Optional privileged LaunchDaemon (SMAppService) streaming live telemetry over XPC and persisting adapter sessions to per-run SQLite |

## The four rules everything hangs on

1. **Every privileged or hardware read sits behind a protocol with a replay
   twin.** `TelemetrySource` has `LiveTelemetrySource` (libproc, sysctl,
   IOReport) and `ReplayTelemetrySource` (NDJSON fixtures). This is what made
   the project buildable by an agent and testable in CI: 130 Swift + 35
   Python tests run without root, without a GPU, without a model.

2. **The event protocol is a contract, not a convention.**
   [`protocol/events.schema.json`](../protocol/events.schema.json) defines
   the v1 NDJSON envelope; Swift and Python implement it by hand and are held
   together by tests that round-trip the *same committed example lines* in
   both languages, validate them against the schema, and pin shared limits
   (the 64 KB line cap lives in the schema's `x-limits` and both decoders
   assert equality with it). Adapters are untrusted: every malformed line
   becomes a typed, counted drop — never a crash, never silence.

3. **One clock.** All timestamps are `mach_continuous_time()` nanoseconds —
   Python reads the same clock via ctypes. Cross-clock adapters declare
   their offset through an NTP-style `clock_sync` handshake (min-RTT
   estimate); the timeline assembler maps event clocks onto the sample clock
   before anything renders, so correlation is never an accident of drift.

4. **System-wide and per-process signals are different types**
   (`SystemWideSample` vs `ProcessSample`), different SQLite tables, and
   visually distinct timeline bands. Comparing package power to one
   process's CPU% produces analysis that looks meaningful and isn't; the
   type system forbids it.

## Module map

```
Sources/LoupeCore      Pure: protocol types + decoder, Timebase, clock-offset math,
                       samples model, SessionMetrics, LTTB, SortedSearch,
                       AnnotationEngine, SessionFilePair. No I/O.
Sources/LoupeSampler   Telemetry: LiveTelemetrySource (libproc/sysctl),
                       IOReportPowerReader (dlopen'd private framework, resolve-by-
                       name, degrade-to-nil), replay sources, EventSocketServer
                       (adapter ingest), XPC service/client, ThermalStateMonitor.
Sources/LoupeStore     GRDB/SQLite: one file per session (WAL), migrations,
                       SessionStore actor, SessionEventRouter (batched persistence).
Sources/LoupeBench     Benchmark spec (YAML), statistics, report assembly,
                       CooldownGate, RunComparison, exports.
Sources/LoupeApp       SwiftUI: sidebar shell, timeline, results, comparison,
                       daemon management. View models are headless-testable.
Sources/loupedaemon    Thin composition root: XPC listener + socket ingest +
                       SIGTERM draining + --register/--status/--unregister flags.
adapters/loupe-mlx     Python: LoupeInstrument wraps mlx-lm with pluggable sinks
                       (daemon socket / file); recorder and bench are thin loops
                       over the same instrument.
adapters/loupe-llamacpp Swift: drives llama-server /completion (server timings =
                       per-request truth), polls /metrics at 10 Hz, computes KV
                       from architecture params, resolves the server PID from its
                       listening socket.
protocol/              The schema + committed cross-language examples.
fixtures/              Golden recordings: a real 60s MLX session (21,318 events),
                       a real benchmark report, real llama-server HTTP responses.
```

## How data flows

**Live (instrumented):** adapter wraps the generation loop → protocol-v1
events over a Unix socket (non-blocking bounded queue; a missing daemon means
counted drops, never a stalled decode) → daemon validates every line →
batched inserts into per-run SQLite. In parallel, the daemon streams 10 Hz
telemetry to the app over XPC. Both paths process commands through single
ordered pumps — fire-and-forget task hops proved reorderable under load, so
ordering is structural, not probabilistic.

**Replay/analysis:** a session is a file pair (`<base>.ndjson` events +
`<base>.system.ndjson` samples). The app loads both concurrently off the
main actor, unifies clocks, computes chart points (LTTB-capped at 2k, spikes
preserved by construction), per-request metrics, swimlane geometry, and
annotations in one pass, then renders. Scrubbing touches exactly two views.

**Benchmark:** `loupe-bench` reads the YAML spec; per (context × repeat) it
waits for thermal nominal (or a clean timeout), spawns one Python process for
one request at an exact token count, discards warmups, and assembles a
report whose structure is pinned by a golden file.

## How it was built and verified

- **Spec-driven, one task per commit.** Twenty-two milestone commits
  (M0.1–M3.3), each landing with its acceptance criteria as executable
  tests before the commit. TDD on everything with crisp math (timebase,
  protocol, LTTB, statistics, annotation rules).
- **Real fixtures, recorded deliberately.** The baseline session is a real
  Qwen2.5-0.5B run; the llama.cpp fixtures are actual llama-server
  responses; the benchmark baseline came from a real sweep (TTFT p50
  107→273 ms, decode 277→192 tok/s across 64→256 context). Golden files are
  never regenerated to make a test pass — the one record-mode that exists
  fails loudly while recording.
- **Adversarial review loops.** Two multi-agent review passes (four-angle
  simplification, five-angle correctness) ran over the codebase after the
  milestones; confirmed findings — including an empirically-reproduced
  actor-ordering race and a daemon shutdown data-loss path — were fixed with
  regression tests, and two silent behavior changes introduced *by the
  cleanup itself* were caught by a history-aware reviewer and reverted with
  pinning tests.
- **Hardware truths get hardware tests.** CPU% tracks `top` under a
  controlled spin load (`LOUPE_HARDWARE_TESTS=1`); the IOReport reader was
  verified live reading real GPU/power channels without root; adapter
  overhead <1% is measured against the real model, not asserted.

## Known gaps (deliberate, tracked)

- **Distribution signing**: `make dist` produces the DMG; notarization
  awaits a Developer ID certificate. The XPC listener's peer-signature check
  is a pre-release gate blocked on the same.
- **Daemon validation steps 3–8** (System Settings approval, streaming
  check, reboot survival, denial path) need a human at the machine —
  scripted in [daemon-validation.md](daemon-validation.md); registration
  through `requiresApproval` is already validated headlessly.
- **In-app recording UX**: recording runs through `make record-fixture` /
  the adapters; the app opens what they produce. Wiring record/stop into the
  UI is the top of the M4+ backlog, alongside the baseline fixture's missing
  thermal-state change.
- **M4–M6** (benchmark matrix, live monitoring, own-engine integration) are
  intentionally unplanned until M3 feedback lands, per the implementation
  spec.
