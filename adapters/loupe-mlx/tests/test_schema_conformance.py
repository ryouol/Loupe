"""The schema file is the contract; both language mirrors must stay inside it.

These tests pin three properties: the schema itself is well-formed, every
committed valid example passes it, every parseable malformed example fails it,
and everything the Python encoder emits conforms.
"""

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from loupe_mlx.events import (
    ClockSync,
    DecodeTick,
    Envelope,
    ErrorEvent,
    ModelLoadEnd,
    ModelLoadStart,
    PrefillEnd,
    RequestEnd,
    RequestStart,
    SessionStart,
    encode_line,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA = json.loads((REPO_ROOT / "protocol/events.schema.json").read_text())
VALIDATOR = Draft202012Validator(SCHEMA)
VALID_LINES = (REPO_ROOT / "protocol/examples/v1-events.ndjson").read_bytes().splitlines()
MALFORMED_LINES = (REPO_ROOT / "protocol/examples/v1-malformed.ndjson").read_bytes().splitlines()


def test_schema_itself_is_valid() -> None:
    Draft202012Validator.check_schema(SCHEMA)


def test_every_valid_example_conforms() -> None:
    for line in VALID_LINES:
        errors = list(VALIDATOR.iter_errors(json.loads(line)))
        assert not errors, f"{line!r}: {[e.message for e in errors]}"


def test_every_parseable_malformed_example_fails_validation() -> None:
    parseable = 0
    for line in MALFORMED_LINES:
        try:
            instance = json.loads(line)
        except ValueError:
            continue
        parseable += 1
        assert not VALIDATOR.is_valid(instance), f"schema accepted junk: {line!r}"
    assert parseable >= 7, "malformed corpus should be mostly parseable JSON"


ENCODABLE_PAYLOADS = [
    SessionStart(adapter="loupe-mlx", adapter_version="0.0.1", runtime="mlx", pid=99),
    ClockSync(t0=1, t1=2, t2=3, t3=4),
    ModelLoadStart(model_id="mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
    ModelLoadEnd(model_id="m", ok=True, weights_bytes=123),
    ModelLoadEnd(model_id="m", ok=False),
    RequestStart(prompt_tokens=7),
    RequestStart(),
    PrefillEnd(prompt_tokens=7),
    DecodeTick(output_tokens=1, kv_cache_bytes=2, active_memory_bytes=3),
    RequestEnd(output_tokens=9, finish_reason="stop"),
    ErrorEvent(code="c", message="m"),
]


@pytest.mark.parametrize("payload", ENCODABLE_PAYLOADS, ids=lambda p: type(p).__name__)
def test_encoder_output_conforms(payload) -> None:
    request_id = "q-1" if payload.EVENT in {
        "request_start", "prefill_end", "decode_tick", "request_end"
    } else None
    envelope = Envelope(ts=123, run_id="r-1", payload=payload, request_id=request_id)
    errors = list(VALIDATOR.iter_errors(json.loads(encode_line(envelope))))
    assert not errors, [e.message for e in errors]
