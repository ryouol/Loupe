#!/usr/bin/env python3
"""Validate the bundled zero-cost replay and its privacy contract."""

from __future__ import annotations

import json
import math
import re
from pathlib import Path
from typing import Any

from loupe_mlx.events import decode_line

BASE = Path("Resources/Samples/demo-session")
EVENT_PATH = BASE.with_suffix(".ndjson")
SAMPLE_PATH = Path(str(BASE) + ".system.ndjson")
SANITIZED_HTTP_FIXTURES = (
    Path("fixtures/llamacpp/props.json"),
    Path("fixtures/llamacpp/completion-stream.txt"),
)
FORBIDDEN_EVENT_KEYS = {"prompt", "content", "generatedText", "outputText"}
TELEMETRY_KEYS = {"system", "process"}
SYSTEM_KEYS = {
    "ts",
    "thermalState",
    "memoryUsedBytes",
    "memoryFreeBytes",
    "swapUsedBytes",
    "gpuBusyPercent",
    "gpuPowerMilliwatts",
    "anePowerMilliwatts",
    "packagePowerMilliwatts",
}
PROCESS_KEYS = {"ts", "pid", "cpuPercent", "rssBytes"}
SENSITIVE_PATTERNS = (
    re.compile(rb"/(?:Users|home)/[^/\s]+/"),
    re.compile(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    re.compile(rb"(?:sk-|ghp_|AKIA)[A-Za-z0-9_-]{8,}"),
)


def nested_keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        return set(value).union(*(nested_keys(item) for item in value.values()))
    if isinstance(value, list):
        return set().union(*(nested_keys(item) for item in value))
    return set()


def finite_number(value: Any, *, minimum: float = 0) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= minimum
    )


event_blob = EVENT_PATH.read_bytes()
sample_blob = SAMPLE_PATH.read_bytes()
for fixture in (EVENT_PATH, SAMPLE_PATH, *SANITIZED_HTTP_FIXTURES):
    fixture_blob = fixture.read_bytes()
    for pattern in SENSITIVE_PATTERNS:
        assert pattern.search(fixture_blob) is None, f"sensitive value in {fixture}"
assert json.loads(SANITIZED_HTTP_FIXTURES[0].read_bytes())["model_path"] == "fixture-model.gguf"
assert b'"prompt":"[sanitized fixture prompt]"' in SANITIZED_HTTP_FIXTURES[1].read_bytes()

event_objects = [json.loads(line) for line in event_blob.splitlines()]
events = [decode_line(line) for line in event_blob.splitlines()]
samples = [json.loads(line) for line in sample_blob.splitlines()]
assert len(events) >= 10, "sample event fixture is too small"
assert len(samples) >= 10, "sample telemetry fixture is too small"
assert len({event.run_id for event in events}) == 1, "sample mixes run identifiers"
assert [event.ts for event in events] == sorted(event.ts for event in events)
assert event_objects[0]["event"] == "session_start"
for value in event_objects:
    assert not (nested_keys(value) & FORBIDDEN_EVENT_KEYS), "sample contains text-bearing fields"

active_requests: set[str] = set()
prefilled_requests: set[str] = set()
seen_requests: set[str] = set()
output_tokens: dict[str, int] = {}
completed_requests = 0
started = False
for event in events:
    if event.event == "session_start":
        assert not started, "sample contains an unexpected reconnect"
        started = True
    else:
        assert started, "session_start must be first"

    if event.event == "request_start":
        assert event.request_id not in seen_requests
        seen_requests.add(event.request_id)
        active_requests.add(event.request_id)
        output_tokens[event.request_id] = 0
    elif event.event == "prefill_end":
        assert event.request_id in active_requests
        assert event.request_id not in prefilled_requests
        prefilled_requests.add(event.request_id)
    elif event.event == "decode_tick":
        assert event.request_id in active_requests
        assert event.request_id in prefilled_requests
        assert event.payload.output_tokens >= output_tokens[event.request_id]
        output_tokens[event.request_id] = event.payload.output_tokens
    elif event.event == "request_end":
        assert event.request_id in active_requests
        assert event.payload.output_tokens >= output_tokens[event.request_id]
        active_requests.remove(event.request_id)
        prefilled_requests.discard(event.request_id)
        output_tokens.pop(event.request_id)
        completed_requests += 1
assert started
assert not active_requests
assert completed_requests >= 2

last_timestamp = -1
for row in samples:
    assert set(row) == TELEMETRY_KEYS, "sample telemetry keys drifted"
    assert not (nested_keys(row) & FORBIDDEN_EVENT_KEYS), (
        "sample telemetry contains text-bearing fields"
    )
    system = row["system"]
    process = row.get("process")
    assert set(system) == SYSTEM_KEYS, "sample system telemetry keys drifted"
    assert isinstance(process, dict) and set(process) == PROCESS_KEYS, (
        "sample process telemetry keys drifted"
    )
    timestamp = system["ts"]
    assert isinstance(timestamp, int) and timestamp >= last_timestamp
    last_timestamp = timestamp
    assert system["thermalState"] in {"nominal", "fair", "serious", "critical"}
    for key in ("memoryUsedBytes", "memoryFreeBytes", "swapUsedBytes"):
        assert finite_number(system[key])
    if "gpuBusyPercent" in system:
        assert finite_number(system["gpuBusyPercent"])
        assert system["gpuBusyPercent"] <= 100
    for key in ("gpuPowerMilliwatts", "anePowerMilliwatts", "packagePowerMilliwatts"):
        if key in system:
            assert finite_number(system[key])
    if process is not None:
        assert process["ts"] == timestamp
        assert isinstance(process["pid"], int) and process["pid"] > 0
        assert finite_number(process["cpuPercent"])
        assert finite_number(process["rssBytes"])

print(f"bundled sample: {len(events)} events, {len(samples)} samples")
