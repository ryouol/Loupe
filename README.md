# Loupe

A native macOS profiler for local AI inference on Apple Silicon. It correlates
system telemetry (CPU, memory, GPU, thermal, power) with runtime-level inference
events (model load, prefill, decode, KV cache) on a single timeline.

- Conventions and architecture rules: [CLAUDE.md](CLAUDE.md)
- Task-ordered build plan: [IMPLEMENTATION.md](IMPLEMENTATION.md)

## Requirements

macOS 15+ on Apple Silicon, Xcode 16+, and `xcodegen`, `swift-format`, `uv` on
`PATH`. `llama-server` is needed later (M3).

## Quick start

```bash
make bootstrap   # generate the Xcode project, resolve deps, set up the venv
make build       # swift build + xcodebuild the app
make test        # swift test + pytest
```

Before M0.6, set your Apple Developer Team ID in `Local.xcconfig` (created from
`Local.xcconfig.template` on bootstrap). It is gitignored — never commit it.
