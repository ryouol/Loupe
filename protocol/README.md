# Event protocol

Versioned NDJSON event schema — the source of truth for every adapter.
[`events.schema.json`](events.schema.json) is the contract. Changing it means
bumping `v`, updating fixtures, and updating every adapter in the same commit.

## v3 envelope

One event per line:

```json
{"v":3,"seq":7,"ts":123456789,"runId":"...","requestId":"...","event":"decode_tick","payload":{...}}
```

`ts` is `mach_continuous_time()` nanoseconds **on the emitter's clock**; the
`clock_sync` four-timestamp handshake (t0–t3) lets the app map adapter
timestamps onto its own clock.

Events: `session_start`, `clock_sync`, `model_load_start`, `model_load_end`,
`request_start`, `prefill_end`, `decode_tick`, `request_end`, `error`, and the
terminal `transport_summary`.
`request_*`, `prefill_end`, and `decode_tick` require a `requestId`. It is
unique for the lifetime of a logical `runId`, including after an adapter
process relaunch, so request evidence cannot alias an earlier window.
`decode_tick` carries cumulative `outputTokens`, `activeMemoryBytes`, and one
typed memory observation:

- `kvCacheBytes` with `runtime_measured_kv` or
  `architecture_modeled_kv`; or
- `allocatorMemoryGrowthBytes` with `allocator_delta_proxy`.

Allocator growth includes non-KV allocations and never drives KV-specific
findings. The timestamp of the first tick whose `outputTokens` is greater than
zero is the observable first-output boundary. Loupe defines TTFT as
`request_start` → that timestamp; `prefill_end` is not mislabeled as TTFT.

`seq` starts at one and increases once for every attempted application event.
The terminal summary uses the next sequence number and reports how many prior
events the producer transport dropped. A received, internally consistent
summary can close producer accounting; a missing summary leaves the total
unknown. Sequence gaps still provide an observed lower bound. The app also
counts its own parser, buffering, validation, and persistence losses instead of
assuming the producer summary covers downstream stages.

Producer-side drops are evidence only when the app receives a valid window and
its terminal summary. If the initial `session_start`, the connection, or the
summary itself cannot reach the app, Loupe reports the producer total as
unknown; an adapter-local counter is not presented as app-observed evidence.

After an adapter process exits, a replacement may open a new producer window
for the same logical run: it begins with `session_start`, resets `seq` to one,
retains globally unique request IDs, and closes with its own summary. Loupe
aggregates every closed window; a replacement after an interrupted window is
still replayable, but any unclosed or invalid window leaves the total unknown.

`request_end.decodeDurationNs`, when present, is the runtime-measured full
`prefill_end` → `request_end` generation interval, including the first output
token. A sequenced request with output tokens but no defensible interval is
omitted from throughput metrics rather than publishing a partial-window rate.

## v1/v2 replay

Version 2 remains accepted with sequencing, terminal summaries, and runtime
decode intervals, but its `kvCacheBytes` has no typed provenance. Version 1
also remains accepted; it has no `seq`, terminal summary, or runtime decode
interval. Loupe therefore labels v1 recording-time acquisition loss as
unknown; replay parser drops are still recomputed from source bytes. New
adapters must emit v3.

## Implementations

The Swift types (`Sources/LoupeCore/Protocol/`) and the Python mirror
(`adapters/loupe-mlx/src/loupe_mlx/events.py`) are hand-written; drift is
caught by tests in both languages that round-trip the same committed examples
under [`examples/`](examples/) and validate v3 against the schema. Decoders
never crash on malformed input: every bad line becomes a typed drop reason and
a counter bump, lines over 64 KB are rejected before parsing, and numeric
ranges match the Swift `UInt32`/`UInt64` and `Int32` wire types exactly.
