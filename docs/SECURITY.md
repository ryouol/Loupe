# Security model

This document describes implemented controls and remaining release gates. It
is not a claim of an independent audit.

## Protected assets

- prompts indirectly observable through token counts and timing;
- model and runtime identifiers;
- per-process and machine telemetry;
- benchmark results and exported evidence;
- the root helper's ability to read privileged telemetry.

Loupe does not intentionally record prompt text in the event protocol. A user
can still put sensitive text in a session name or benchmark corpus, so exports
must be handled as potentially confidential.

## Trust boundaries and controls

### Runtime adapter → app

Adapters are untrusted, even though they run under the same user account.
Input is protected by owner-only Unix permissions, peer-UID checks, bounded
connections/queues/lines, exact JSON keys, schema field limits, run pinning,
event-sequence checks, and observed-PID ownership checks. Invalid input becomes
a counted denial or degraded state; it never creates a root-owned file.

### App → disk

Loupe stores sessions below the user's Application Support directory. All
Loupe directories are forced to mode 0700 and databases/manifests/portable
evidence to 0600. Files use generated UUIDs, never adapter strings. SQLite WAL
and shared-memory sidecars receive the same owner-only mode. Existing nodes
are checked with `lstat`, owner identity, and a single-link requirement before
permissions or database contents are touched, so symlink/hard-link substitution
fails closed. Manifests and benchmark reports are
written to exclusive 0600 siblings, synced, and renamed into place; Python
adapter files reject symlinks and multi-link targets before truncation.

### App → root helper

The helper is telemetry-only. Its build target does not contain the adapter
socket, replay loader, or persistence implementation. It validates
active-console UID plus a designated same-team/bundle signing requirement
before accepting XPC, then requires a protocol-version handshake. Unsigned
builds fail closed. Connection death cancels sampling. Connections and pending
start/stop commands are bounded.
During recording, the app keeps the local row timestamp and process sample,
then merges only the latest helper GPU/power fields. The helper never receives
adapter events or owns a session database. Live telemetry retains only the
newest 64 rows and the app-side XPC receiver retains only the newest 256 rows,
so a stalled consumer cannot create an unbounded producer backlog.

### llama.cpp HTTP

The adapter only accepts unauthenticated numeric-loopback `http`/`https` URLs
(`127.0.0.1` or `::1`), avoiding hostname-resolution ambiguity. It refuses
embedded credentials and remote hosts, disables redirects and proxies,
requires the listening server PID to belong to the current user, validates 2xx
responses, applies timeouts, and bounds metadata, SSE lines, total stream
bytes, tokens, prompt bytes, and KV dimensions. Metadata limits are enforced
while response bytes arrive, before a complete body is buffered.

## Resource bounds

| Surface | Default bound |
|---|---:|
| Protocol line | 65,536 bytes |
| Active recording adapter connections | 1 |
| Generic socket server connections | 16 (hard maximum 64) |
| Socket command buffer | 2,048 chunks |
| Decoded event buffer | 1,024 events |
| Privileged helper connections | 4 (hard maximum 16) |
| Privileged start/stop commands | 64 per connection |
| Live telemetry producer | newest 64 rows |
| App XPC telemetry receiver | newest 256 rows / 65,536 bytes per payload |
| Sessions per generic router | 8 (hard maximum 64) |
| Pending events per session | 4,096 (hard maximum 65,536) |
| Recorded events per session | 100,000 |
| Recorded event evidence | 64 MiB |
| Recorded telemetry rows per session | 100,000 |
| Persisted lifecycle transitions | 256 most recent states |
| Imported runtime-event file | 64 MiB / 500,000 rows |
| Imported telemetry file | 128 MiB / 100,000 rows |
| Imported benchmark report | 16 MiB |
| llama metadata response | 1 MiB |
| llama completion stream | 16 MiB |
| llama prompt | 65,536 UTF-8 bytes |

Portable replay export is streamed through exclusive 0600 temporary files and
renamed into place. Its memory use is bounded by one encoded row.

## Known residual risks

- IOReport is a private framework and may change across macOS/hardware. Missing
  channels degrade to `nil`; release testing must cover supported hardware.
- PID ownership prevents cross-user attachment but cannot by itself prove a
  process is a specific runtime binary. PID lifetime/reuse should be monitored
  during long recordings in a future hardening pass.
- Evidence JSON/CSV is not cryptographically signed. Metrics and hashes are
  derived from the same immutable load snapshot, and export refuses a source
  that changed after load; this supports integrity comparison but not
  non-repudiation. CSV text cells are neutralized against spreadsheet-formula
  execution.
- No external penetration test, static analysis service, or independent
  dependency/license audit has been completed in this workspace.
- Swift package and Python locks reduce dependency drift; release owners still
  need vulnerability review and reproducible-build evidence.

## Reporting

Until a public security address is configured, report vulnerabilities
privately to the repository owner. Do not open a public issue containing an
exploit, session data, or prompt-derived information.
