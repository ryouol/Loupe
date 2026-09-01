# Event protocol

Versioned NDJSON event schema — the source of truth for every adapter.
[`events.schema.json`](events.schema.json) is the contract. Changing it means
bumping `v`, updating fixtures, and updating every adapter in the same commit.

## v1 envelope

One event per line:

```json
{"v":1,"ts":123456789,"runId":"...","requestId":"...","event":"decode_tick","payload":{...}}
```

`ts` is `mach_continuous_time()` nanoseconds **on the emitter's clock**; the
`clock_sync` four-timestamp handshake (t0–t3) lets the app map adapter
timestamps onto its own clock.

Events: `session_start`, `clock_sync`, `model_load_start`, `model_load_end`,
`request_start`, `prefill_end`, `decode_tick`, `request_end`, `error`.
`request_*`, `prefill_end`, and `decode_tick` require a `requestId`.
`decode_tick` carries `outputTokens`, `kvCacheBytes`, `activeMemoryBytes`.

## Implementations

The Swift types (`Sources/LoupeCore/Protocol/`) and the Python mirror
(`adapters/loupe-mlx/src/loupe_mlx/events.py`) are hand-written; drift is
caught by tests in both languages that round-trip the same committed examples
under [`examples/`](examples/) and validate them against the schema. Decoders
never crash on malformed input: every bad line becomes a typed drop reason and
a counter bump, lines over 64 KB are rejected before parsing, and numeric
ranges match the Swift `UInt32`/`UInt64` and `Int32` wire types exactly.
