# Fixtures

Recorded sessions for offline, root-free tests. Treated as golden files.
Never regenerate a golden fixture just to make a test pass — that is a bug,
not a fix. Record new ones with `make record-fixture NAME=<name>`.

## baseline-session

A real ~60s `mlx-community/Qwen2.5-0.5B-Instruct-4bit` run recorded with
`scripts/record-fixture.sh`: 105 requests, 21,318 protocol-v1 events
(21,000 decode ticks), 739 system samples at 10 Hz spanning model load
through the last request.

**Known gap:** the run never left `thermalState == nominal` — a 0.5B model
cannot heat-soak this machine in 60 seconds. The M2.3 thermal-throttling
annotation rule needs a synthetic trigger fixture or a re-recorded baseline
from a longer run on louder hardware (`make record-fixture` with a bigger
model via `LOUPE_FIXTURE_MODEL`).
