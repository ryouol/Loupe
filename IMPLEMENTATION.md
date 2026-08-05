# Loupe — Implementation Spec for Claude Code

A task-ordered build plan. Each task is one branch, one PR, one verifiable acceptance criterion. Hand the agent one task at a time. Do not hand it a milestone.

## Prerequisites you must supply before the agent starts

The agent cannot obtain these:

1. An Apple Developer Team ID. `SMAppService` daemon registration requires a signed app. Put it in `Local.xcconfig` (gitignored): `DEVELOPMENT_TEAM = ABCDE12345`.
2. Tooling: `xcodegen`, `swift-format`, `uv` (or `python3 -m venv`), Xcode 16+.
3. A test model. One 3B-class MLX model and the equivalent GGUF, pinned by revision hash. Put the paths in `Local.xcconfig` too — never hardcode `~/models/...` in the repo.
4. `llama-server` binary on `PATH` for M3.

## The rule that makes this agent-buildable

Every privileged or hardware-dependent read sits behind a protocol with two implementations: live and replay.

```swift
protocol TelemetrySource: Actor {
    func stream() -> AsyncStream<SystemSample>
}

actor LiveTelemetrySource: TelemetrySource   // IOReport / libproc. Needs root.
actor ReplayTelemetrySource: TelemetrySource // Reads fixtures/*.ndjson. Needs nothing.
```

The agent develops against `Replay` and verifies with `make test` on any machine. You run `make build && open Loupe.app` to validate `Live` on real hardware. Without this split the agent is blind — it writes code it cannot execute and you become the test harness.

Record fixtures early (task M0.4) and treat them as golden files.

## M0 — Foundations (target: 1 week)

### M0.1 Repo scaffold

Create the SPM package, `project.yml`, `Makefile`, `.gitignore`, `.swift-format`, and the directory tree from CLAUDE.md. Every target exists and compiles as an empty stub. CI workflow runs `make lint test`.

**Accept:** `make bootstrap && make build && make test` succeeds on a clean clone. `xcodegen` is the only thing that writes the pbxproj.

### M0.2 Timebase

`LoupeCore/Timebase.swift`. `mach_continuous_time()` → nanoseconds via `mach_timebase_info`. Include the adapter-clock-offset handshake type: NTP-style four-timestamp round trip producing `(offsetNs, uncertaintyNs)`.

**Accept:** unit tests for monotonicity, timebase conversion on a fake numer/denom, and offset estimation against a synthetic clock with known skew and jitter.

### M0.3 Event protocol v1

`protocol/events.schema.json` plus generated Swift `Codable` types and a Python dataclass mirror. Envelope:

```json
{"v":1,"ts":123456789,"runId":"...","requestId":"...","event":"decode_tick","payload":{...}}
```

Events: `session_start`, `clock_sync`, `model_load_start`, `model_load_end`, `request_start`, `prefill_end`, `decode_tick`, `request_end`, `error`. `decode_tick` carries `outputTokens`, `kvCacheBytes`, `activeMemoryBytes`.

**Accept:** round-trip encode/decode tests in both languages against the same fixture file. Malformed input produces a dropped-event counter, never a crash.

### M0.4 Fixture capture tool

`scripts/record-fixture.sh` — runs a real session and writes `fixtures/<name>.ndjson` plus a `fixtures/<name>.system.ndjson` of system samples. Commit `baseline-session` (a ~60s MLX run that includes at least one thermal state change).

**Accept:** `make replay` renders that session end to end without root.

### M0.5 Store

`LoupeStore` on GRDB. Schema from the plan (`runs`, `system_samples`, `inference_events`), WAL mode, migrations, one SQLite file per session under `~/Library/Application Support/Loupe/sessions/`. `host_fingerprint` populated from `sysctl` (chip, core counts, RAM, macOS build).

**Accept:** migration test, 100k-row insert benchmark under 2s, time-range query test.

### M0.6 Privileged daemon skeleton

`loupedaemon` + `SMAppService` registration + XPC round trip returning a canned sample stream. The app shows install/uninstall state and a "daemon unavailable — running in observed mode" degraded path.

**Accept:** daemon registers, survives reboot, streams at 10 Hz to a debug view. Denying the install must degrade gracefully, not crash or block launch — test that path explicitly.

This is the make-or-break task. If IOReport or SMAppService fights you for more than two days, switch to the long-lived `powermetrics --sample-rate 100 -f plist` subprocess behind the same `TelemetrySource` protocol and move on. Do not let the agent grind here.

## M1 — MLX benchmark runner (2 weeks)

### M1.1 Live telemetry source

`libproc` per-process CPU/RSS (delta-based), `host_statistics64` memory pressure, `sysctl vm.swapusage`, `ProcessInfo.thermalState` + change notifications. 100 ms cadence.

**Accept:** sampled values track `top` within tolerance in an integration test marked `.needsHardware`.

### M1.2 GPU + power channels

IOReport for GPU busy %, GPU/ANE/package power. Resolve channels by name, tolerate missing keys.

**Accept:** on a machine with no matching channels, source yields samples with `nil` GPU fields and the UI hides those charts rather than showing zeros.

### M1.3 MLX adapter

`adapters/loupe-mlx`. Wraps `mlx_lm.load` / `stream_generate`. Emits the M0.3 events over a Unix socket. Memory from `mx.get_active_memory()` / `get_peak_memory()` / `get_cache_memory()`. Events buffer on a background thread — the generation loop never blocks on a socket write.

**Accept:** a pytest that runs a tiny model and asserts event ordering, monotonic timestamps, and that TTFT equals `prefill_end - request_start`. Measure and assert adapter overhead < 1%.

### M1.4 Benchmark harness

Run spec (YAML): model, runtime, quantization, context, batch, prompt corpus, output length, repeats, seed. Warmup discarded. Cooldown gate between runs until `thermalState == .nominal` or a timeout. Reports p50/p95 and run-to-run stddev — never a bare mean.

**Accept:** a golden-file test that a fixed spec produces a stable report structure; a test that the cooldown gate times out cleanly rather than hanging.

### M1.5 Results view

SwiftUI. Run list, per-run summary, the context-length sweep as a chart with error bars.

**Accept:** renders `make replay` data. Snapshot tests.

## M2 — Correlated timeline (2 weeks)

### M2.1 Merge + downsample

Join system samples and inference events on the shared clock with the offset applied. LTTB downsampling to ~2k points per series.

**Accept:** LTTB unit tests (endpoint preservation, peak preservation); merge test asserting correct interleave with a known 40 ms offset.

### M2.2 Timeline UI

Phase swimlanes, aligned charts sharing one x-axis and one scrubber. System-wide series render in a visually distinct band from per-process series — this is a correctness requirement, not decoration.

**Accept:** snapshot tests at three window widths; scrubber keeps all lanes aligned.

### M2.3 Annotation engine

Rule-based only. Ship these five:

* decode rate drops >15% within 5s of a thermal state increase → thermal throttling
* decode rate drop + `swap_bytes` rising → memory pressure
* TTFT > 3× the run median → prefill queueing
* `kv_cache_bytes` > 40% of process memory → KV-dominated footprint
* GPU busy < 50% during decode → likely CPU-bound or memory-bandwidth-bound

Each annotation stores its evidence (the exact samples) and links to that moment.

**Accept:** each rule has a synthetic fixture that triggers it and one that must not.

## M3 — llama.cpp + comparison (2 weeks)

### M3.1 llama.cpp adapter

Poll `/metrics` at 10 Hz; take per-request truth from the `/completion` `timings` object (`prompt_ms`, `predicted_ms`, `predicted_per_second`). Compute KV cache size from architecture params rather than reading it. Resolve PID from the listening socket.

**Accept:** tests against recorded HTTP fixtures. No live server needed.

### M3.2 Comparison engine

Diff two runs. Compare the run specs first and render a blocking warning banner listing every dimension that differs. Refuse to show a headline delta when specs mismatch.

**Accept:** mismatched-spec test asserts the banner appears and the delta is suppressed.

### M3.3 Comparison UI + export

Side-by-side table, deltas, CSV/JSON export.

## M4–M6 (scope later, don't plan in detail yet)

* **M4 Benchmark matrix:** `model × runtime × quantization × context × batch`, queued, resumable, exportable.
* **M5 Live monitoring:** process auto-detect, observed vs instrumented mode badge, sliding-window latency percentiles.
* **M6 Own engine integration:** paged KV block map, scheduler decisions, prefix cache hit rate, speculative acceptance.

Re-plan M4 only after M3 ships. Anything written now will be wrong.

## How to run the agent

One task per session. Start each with: "Read CLAUDE.md and IMPLEMENTATION.md. Implement M1.3. Do not touch other tasks." Scope creep across tasks is the main failure mode.

Demand the test first on anything with a parsing or math component (Timebase, protocol, LTTB, annotation rules). These have crisp inputs and outputs, so TDD works well and the agent writes better code when the acceptance criterion is executable.

Review these carefully, they're where agents are weakest here:

* Anything touching `pbxproj`, entitlements, or codesigning
* Concurrency — Swift 6 strict mode will surface real issues; make sure they're fixed, not silenced with `@unchecked Sendable`
* IOReport key handling — verify it degrades on missing keys instead of assuming
* Any code path that can only run as root

When it gets stuck on hardware/privilege, that's the signal the abstraction boundary is wrong. Push it back to the protocol + replay pattern rather than letting it special-case.

Commit fixtures deliberately. If the agent regenerates a golden file to make a test pass, that's a bug, not a fix. Say so in review.
