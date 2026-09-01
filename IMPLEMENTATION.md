# Loupe implementation and release plan

This file describes the current 0.2 architecture. Historical milestone plans
that routed adapter input and persistence through the root helper are obsolete.

## Shipped code slice

### Local session workflow

- User starts/stops a recording in SwiftUI.
- The app creates an opaque SQLite session, protected lifecycle manifest, and
  same-user adapter socket.
- Runtime events are validated for schema, expected run, sequence, token
  monotonicity, and claimed PID owner.
- System sampling begins immediately; per-process sampling attaches after a
  valid `session_start`.
- State transitions survive relaunch and History exposes interrupted,
  degraded, denied, disconnected, reconnecting, failed, and stopped outcomes.
- Stop drains accepted commands, ends the run, and exports a replay pair.

### Demo and evidence

- One-click sanitized sample ships under `Resources/Samples`.
- Analysis provides aligned runtime/telemetry lanes, request metrics, and
  evidence-backed findings.
- JSON/CSV exports include source SHA-256 values and counted parser drops.

### Security boundary

- Root helper is telemetry-only.
- Its build target contains no adapter socket, replay loader, or persistence
  implementation; `loupedaemon` depends only on `LoupeCore` and
  `LoupeTelemetry`.
- Production XPC requires active-console UID plus same-team/bundle designated
  requirement and protocol negotiation.
- Recording continues locally while the optional helper connects, then merges
  only helper GPU/power fields onto local timestamped rows.
- User socket/storage is owner-only, same-UID, opaque-named, and bounded.
- llama.cpp HTTP is bounded, loopback-only, redirect-free, and proxy-free.

### Benchmark integrity

- Comparisons gate on the complete spec, prompt-corpus digest, warmup/repeats,
  full host/OS fingerprint, report integrity, tool/adapter/runtime versions,
  model revision/artifact hash, and dependency-lock hash.
- Missing legacy provenance blocks deltas but does not block viewing a report.

## Required acceptance commands

```bash
make bootstrap
make lint
make build
make test
make verify
make replay
```

No privileged, signing, or hardware result may be inferred from these commands.
Signed helper and distribution acceptance is separately documented in
`docs/daemon-validation.md` and `docs/distribution.md`.

## Next engineering slices

1. Run and fix the full XCTest/Xcode matrix on a host with full Xcode.
2. Add PID start-time tracking to close the long-session PID-reuse residual
   risk.
3. Add signed evidence bundles if paid pilots require non-repudiation.
4. Run an external security review and dependency-license audit.
5. Validate adapters against a pinned real MLX model and current llama-server
   on the supported chip/macOS matrix.

Do not add a cloud service, licensing backend, or broad runtime matrix until
paid-pilot evidence selects the next product direction.
