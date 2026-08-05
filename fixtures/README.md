# Fixtures

Recorded sessions for offline, root-free tests. Treated as golden files.

`baseline-session` (a ~60s MLX run with at least one thermal state change) is
captured in **M0.4** via `scripts/record-fixture.sh`. Never regenerate a golden
fixture just to make a test pass — that is a bug, not a fix.
