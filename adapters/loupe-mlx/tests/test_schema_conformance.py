"""The schema file is the contract; both language mirrors must stay inside it."""

import json

import pytest
from jsonschema import Draft202012Validator
from loupe_mlx.events import (
    REQUEST_SCOPED_EVENTS,
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


@pytest.fixture(scope="module")
def validator(schema) -> Draft202012Validator:
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def test_every_valid_example_conforms(validator, valid_lines) -> None:
    for line in valid_lines:
        errors = list(validator.iter_errors(json.loads(line)))
        assert not errors, f"{line!r}: {[e.message for e in errors]}"


def test_every_parseable_malformed_example_fails_validation(validator, malformed_lines) -> None:
    parseable = 0
    for line in malformed_lines:
        try:
            instance = json.loads(line)
        except ValueError:
            continue
        parseable += 1
        assert not validator.is_valid(instance), f"schema accepted junk: {line!r}"
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
def test_encoder_output_conforms(payload, validator) -> None:
    request_id = "q-1" if payload.EVENT in REQUEST_SCOPED_EVENTS else None
    envelope = Envelope(ts=123, run_id="r-1", payload=payload, request_id=request_id)
    errors = list(validator.iter_errors(json.loads(encode_line(envelope))))
    assert not errors, [e.message for e in errors]
