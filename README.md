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
make replay      # open the app on the bundled baseline session, no root needed
```

Set your Apple Developer Team ID in `Local.xcconfig` (created from
`Local.xcconfig.template` on bootstrap) to sign builds and register the
privileged daemon. It is gitignored — never commit it.

## Distribution

Loupe ships as a direct-download DMG — no App Store. `make dist` builds it;
with signing + notarization credentials it produces a Gatekeeper-clean image
ready to host on any website. See [docs/distribution.md](docs/distribution.md).
