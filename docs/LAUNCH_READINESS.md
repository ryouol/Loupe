# Launch readiness

Snapshot date: 2026-09-01. This is an engineering status, not a launch claim.

## Implemented

- root helper reduced to telemetry-only;
- privileged helper isolated in a source/dependency/binary allow-list that
  excludes adapter ingest, replay, and persistence code;
- active-console UID and runtime-derived same-team/bundle XPC requirement;
- protocol negotiation before helper sampling;
- owner-only, same-UID, connection/buffer/line-bounded adapter socket;
- exact protocol and telemetry keys, field constraints, and semantic event
  sequencing in Swift and Python;
- protocol-v3 event/sample sequencing (with v2 replay compatibility), terminal
  producer summaries, and
  durable acquisition exact/lower-bound/breakdown metadata across socket,
  XPC, SQLite, manifest, portable replay, History, UI, JSON, and CSV;
- opaque UUID storage names and owner-only database/sidecar/manifest/export modes;
- exclusive 0600 temporary writes for manifests, replay pairs, adapter files,
  and benchmark reports before atomic rename;
- in-app start/stop state machine with denied, degraded, disconnect, reconnect,
  interrupted, failed, and stopped history;
- PID-owner validation and runtime event sequence checks;
- sanitized bundled sample with explicit historical-v1 provenance and
  one-click sample entry points;
- hashed JSON/CSV evidence export with matching filenames, SHA-256 values,
  counts, duration, thermal states, replay-parser drops, and acquisition loss;
- unit-correct process CPU/RSS, GPU utilization, GPU power, and package-power
  analysis lanes with shared scrubbing, unavailable-channel hiding,
  metric-preserving downsampling, and accessibility summaries;
- first-output TTFT plus full-window MLX and llama.cpp decode throughput timing,
  including the first output token, with unavailable sequenced intervals
  omitted rather than inferred;
- provenance-typed decode memory: runtime/measured or architecture-modeled KV
  stays distinct from MLX whole-allocator growth, and proxy/legacy values do
  not trigger KV-specific findings;
- single-flight, lock-serialized MLX request lifecycles with monotonic emission
  and close-race handling;
- prompt transport over bounded stdin/pipe paths instead of process arguments;
- exact same-user llama.cpp listener resolution by address family, local
  address, port, and listen state;
- strict benchmark provenance and report-integrity comparison gates;
- loopback-only llama.cpp HTTP client with redirects/proxies disabled and
  response limits enforced while bytes arrive;
- locked Swift and Python dependencies;
- pinned CI actions and unsigned packaging smoke job;
- unique provisional DMG construction with failure cleanup, prior-artifact
  rollback, post-gate atomic publication, and final-name checksum generation;
- product decision, commercial hypothesis, security, privacy, terms, licensing,
  third-party, architecture, and distribution documentation.

## Verified on this workspace host

- Debug and optimized `swift build`: pass with Apple Swift 6.2 strict
  concurrency on arm64 macOS.
- Python adapter suite: 63 passed on Python 3.14.2; one optional live-MLX
  hardware module skipped because MLX was not installed in this environment.
- Bundled legacy sample: 16 protocol events and 20 telemetry rows decode with
  zero replay-parser drops; recording-time acquisition remains correctly
  unknown because this fixture predates protocol v2 metadata.
- A separately compiled optimized no-XCTest runtime harness decoded the 16-line
  v3 fixture with zero parser drops, validated its terminal summary, verified
  q-1's 350 ms first-output TTFT and typed allocator-proxy memory, then decoded
  and semantically validated all 16 v2 compatibility lines.
- A second compiled harness opened IPv4 and IPv6-only loopback listeners and
  verified PID resolution stays exact across UID, listen state, address family,
  local address, and port.
- Strict Swift/Ruff formatting, parse-only validation of every Swift source
  and test file, Actionlint, ShellCheck, `git diff --check`, XcodeGen,
  locked dependency validation, plist validation, and sample validation pass.
- `pip-audit` reports no known vulnerabilities in the locked Python
  development and optional MLX sets; OSV-Scanner reports no issues in the
  Swift/Python locks.
- `LOUPE_ALLOW_TOOLCHAIN_LIMITED_VERIFY=1 bash scripts/verify-release.sh`
  completes and labels itself toolchain-limited.
- Mocked packaging regressions preserve an existing image/checksum across
  candidate-validation and final-checksum failures, remove hidden candidates,
  and publish only a verified candidate; real signing/notarization was not run.
- Command Line Tools-only host limitation is known and detected by the release
  script.

`swift test` stops at `no such module 'XCTest'`. `make build-app` successfully
regenerates the Xcode project, then `xcodebuild` stops because the selected
developer directory is `/Library/Developer/CommandLineTools`. Parse-only test
validation and the compiled runtime harness supplement but do not replace those
XCTest/app-target gates. No app launch, screenshot review, live MLX run,
hardware benchmark, signature, helper install, DMG, or notarization result was
fabricated around those blockers.

Benchmark provenance is also bounded: the CLI hashes the dependency lock, but
the runtime version, model revision, and model artifact SHA-256 are required
operator assertions. This workspace did not independently resolve a model from
those values or produce hardware benchmark evidence.

## Blocked here, mandatory before customer release

| Gate | Owner/equipment required | Pass evidence |
|---|---|---|
| Swift XCTest and Xcode app tests | Full Xcode 16+ | Complete test log, no failures |
| XcodeGen app build/package | Full Xcode + XcodeGen | Release app and unsigned smoke DMG validation |
| Developer ID signing | Certificate owner | Strict app/helper signature output |
| XPC production identity test | Signed test clients and multiple users | Allowed/denied test log |
| Notarization/stapling/Gatekeeper | Notary credentials + clean Mac | notary log, staple validation, `spctl` pass |
| IOReport hardware matrix | Supported M-series machines | channel/result matrix |
| Legal approval | Seller + counsel | approved EULA/privacy/notices |
| Commercial operations | Seller | domain, support/security contact, checkout, tax/refund process |
| External security review | Security owner/vendor | triaged report and resolved high findings |

## No-go conditions

- any privileged change without passing full Swift/XPC tests;
- a helper that accepts unsigned, wrong-team, wrong-bundle, or wrong-user peers;
- any artifact whose name obscures unsigned or unnotarized status;
- benchmark deltas shown with incomplete provenance or invalid run counts;
- legal drafts presented to customers as approved terms;
- published claims of notarization, hardware coverage, security audit, or paid
  customer validation without attached evidence.
