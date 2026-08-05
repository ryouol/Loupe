# Event protocol

Versioned NDJSON event schema — the source of truth for every adapter.

`events.schema.json` (envelope `v:1`) is authored in **M0.3**, alongside
generated Swift `Codable` types and a Python dataclass mirror. Changing the
schema means bumping `v`, updating fixtures, and updating every adapter in the
same commit.
