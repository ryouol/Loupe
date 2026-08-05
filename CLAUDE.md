# Loupe

A native macOS profiler for local AI inference on Apple Silicon. Correlates system telemetry (CPU, memory, GPU, thermal, power) with runtime-level inference events (model load, prefill, decode, KV cache) on a single timeline.

## Non-negotiables

* Apple Silicon only. macOS 15+. Do not write Intel fallbacks or back-compat branches.
* Never edit `*.xcodeproj` directly. Edit `project.yml` and run `xcodegen generate`. A hand-edited pbxproj will be reverted.
* Never commit secrets, Team IDs, or provisioning profiles. Signing config comes from `Local.xcconfig`, which is gitignored.
* Everything must be testable without root and without a GPU. Any component that reads privileged or hardware state goes behind a protocol with a fixture-replay implementation. If you write code that can only be verified by a human running it as root on a Mac Studio, you have written it wrong.
* The event protocol in `protocol/events.schema.json` is the contract. Changing it means bumping `v`, updating fixtures, and updating every adapter in the same commit.

## Layout

```
Sources/LoupeCore/     Shared models, timebase, XPC protocol definitions. No I/O.
Sources/LoupeStore/    SQLite persistence (GRDB). Schema + migrations + queries.
Sources/LoupeSampler/  Telemetry sources. Protocol + live impl + replay impl.
Sources/loupedaemon/   Root LaunchDaemon executable. Thin. Wraps LoupeSampler over XPC.
Sources/LoupeApp/      SwiftUI views + view models. Library target.
Sources/LoupeAppMain/  App entry point. Minimal — just wires LoupeApp up.
adapters/loupe-mlx/    Python package. Instruments mlx-lm.
adapters/loupe-llamacpp/  Swift executable. Polls llama-server HTTP.
protocol/              Versioned NDJSON event schema. Source of truth for all adapters.
fixtures/              Recorded sessions for offline tests. Never regenerate casually.
```

## Commands

```bash
make bootstrap      # xcodegen + resolve deps + install python adapter in a venv
make build          # swift build && xcodebuild -scheme Loupe -destination 'platform=macOS'
make test           # swift test + python -m pytest adapters/
make lint           # swift-format lint --strict
make replay         # run the app against fixtures/baseline-session.ndjson, no root needed
```

Run `make test` before declaring any task complete. If it does not pass, the task is not done.

## Architecture rules

* The GUI never runs as root and never talks to a runtime adapter directly. GUI ← XPC → daemon, and adapters → Unix socket → daemon. All persistence goes through the daemon.
* All timestamps are `mach_continuous_time()` nanoseconds. Never `Date`, never `mach_absolute_time`. Conversion helpers live in `LoupeCore/Timebase.swift` — use them.
* Adapters are untrusted input. Validate against the schema, bound all allocations, never `fatalError` on malformed events — drop the event and increment a counter.
* System-wide signals (GPU %, package power) and per-process signals (CPU, RSS) are different types in the model layer, not just different fields. Do not let them mix.

## Style

* Swift 6 language mode, strict concurrency. Actors for the sampler and store.
* No force unwraps outside tests. No `try!`.
* Prefer `struct` + protocol over class hierarchies.
* Tests are XCTest, colocated in `Tests/<TargetName>Tests/`.
* Comments explain why, never what. If a comment restates the code, delete it.

## Things that will bite you

* `SMAppService.daemon` requires the plist filename to exactly match the `Label` key inside it, and the daemon binary to live at `Contents/MacOS/` in the app bundle.
* IOReport channel key names differ across chip generations. Always resolve by name at runtime and degrade gracefully when a key is absent — never index blindly.
* `proc_pid_rusage` returns cumulative counters. CPU percent is a delta between two samples over wall time; a single sample is meaningless.
* MLX's `mx.get_active_memory()` and RSS disagree, and RSS is the one that's lying (mmap'd weights). Trust the runtime.
