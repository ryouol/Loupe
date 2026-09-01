# Architecture

Loupe 0.2 is intentionally local-first and least-privileged. The app owns
runtime ingest, durable storage, analysis, history, and export. The optional
root helper has one job: stream system-wide telemetry that is not reliably
available to an unprivileged process.

```text
MLX / llama.cpp adapter (user UID)
        │ protocol-v1 NDJSON
        ▼
owner-only Unix socket in ~/Library/Application Support/Loupe/runtime
        │ same-UID + bounded + schema/sequence/PID validation
        ▼
SessionRecorder actor (app, user UID)
        ├── local memory/thermal/process sampler
        ├── optional helper GPU/power fields merged onto the local row clock
        ├── SQLite: opaque UUID filename, 0700 directory, 0600 files
        ├── lifecycle manifest: wait/record/degrade/disconnect/reconnect/stop
        └── portable NDJSON pair for replay and evidence export

signed app ── authenticated XPC ──► optional root telemetry-only helper
```

## Module responsibilities

| Module | Responsibility |
|---|---|
| `LoupeCore` | Pure protocol/model/timebase/metrics/annotation code; no I/O |
| `LoupeTelemetry` | Privileged-helper allow-list: live system sampling and authenticated telemetry-only XPC service |
| `LoupeSampler` | User-process replay, bounded adapter socket, helper client, and recording telemetry composition |
| `LoupeStore` | GRDB persistence, opaque storage IDs, recording state machine, history manifests |
| `LoupeBench` | Benchmark spec/report/provenance/comparison gates |
| `LoupeApp` | Native SwiftUI recording, history, replay, findings, evidence, comparison, helper UI |
| `loupedaemon` | Root composition root depending only on `LoupeCore` + `LoupeTelemetry`; no adapter ingest/replay/storage module linked |

## Recording lifecycle

`SessionRecorder` owns one recording at a time. It writes every state change to
an owner-only manifest so a user can see what happened after relaunch.

1. `preparing`: create/check protected directories and opaque storage.
2. `waitingForAdapter`: bind the same-user socket and sample system telemetry.
3. `recording`: accept a valid `session_start`, verify the claimed PID owner,
   attach per-process telemetry, and persist correlated data.
4. `adapterDisconnected`: keep sampling while the runtime stream is absent.
5. `reconnecting`: accept a same-user reconnection and validate its next event.
6. `degraded` or `denied`: persist and show resource, storage, identity, or
   protocol failures rather than silently pretending the trace is complete.
7. `stopped`: drain accepted socket commands, end SQLite state, and materialize
   the portable replay pair through bounded-memory owner-only temporary files.

An unclean app exit leaves SQLite rows and the manifest intact. History marks a
non-terminal manifest as `interrupted`; it does not invent a successful stop.

## Adapter boundary

`EventSocketServer` enforces:

- a 0700 parent and 0600 socket owned by the app UID;
- peer UID equality via `getpeereid`;
- one adapter connection per active recording (the reusable socket server has
  a 16-connection default and hard maximum of 64) plus bounded command/event
  streams;
- a 64 KiB unterminated-line cap;
- strict v1 envelope and payload keys, lengths, positive PID, and request IDs;
- an expected run ID, event sequencing/timestamps, monotonic decode tokens, and a claimed
  PID owned by the same user before process telemetry begins.

Adapter run IDs are data only. `SessionStore` uses a generated UUID for every
database, manifest, and export filename, preventing path traversal.

## Privileged helper boundary

The helper exports only handshake/start/stop telemetry methods. Before
exporting any root-owned object, its listener requires:

- a separate build target that contains no adapter socket, replay loader, or
  persistence implementation;

- the connection's effective UID equals the active `/dev/console` owner;
- the helper has a real signing-team identifier;
- the peer matches bundle ID `ai.squint.loupe`, an Apple-generic anchor, and
  the helper's runtime-derived team identifier;
- the client negotiates the current event protocol before sampling starts;
- sampling cadence is clamped to 10–10,000 ms and one broadcaster exists per
  connection;
- at most four helper connections and 64 pending start/stop commands are
  retained;
- the live producer keeps its newest 64 rows and the app receiver keeps its
  newest 256 validated rows, so a signed but faulty or stalled client cannot
  grow telemetry buffers without bound.

Unsigned/ad-hoc builds have no team identifier, fail closed, and the app
disables helper installation. Tests use an explicit in-process policy only for
anonymous XPC endpoints.

## Clocks and signal semantics

Runtime and telemetry timestamps use `mach_continuous_time` nanoseconds.
`clock_sync` maps another emitter clock before metrics or annotations are
computed. System-wide and per-process values remain different Swift types,
tables, and visual lanes; package power is never attributed to one PID.

## Replay and evidence

Every completed recording produces `<opaque-id>.ndjson` plus
`<opaque-id>.system.ndjson`. Replay parses the pair independently with counted
drops, hard file/row limits, unified clocks, and LTTB-capped charts. Evidence
export includes SHA-256 for both source files, request metrics, findings,
source counts, and drop counts; CSV cells cannot execute spreadsheet formulas.
The durable-to-portable export streams one validated row at a time rather than
materializing a complete worst-case session in memory.
