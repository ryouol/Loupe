from pathlib import Path

import pytest

from loupe_mlx.events import (
    MAX_LINE_BYTES,
    PAYLOAD_TYPES,
    DropCounter,
    DropReason,
    Envelope,
    ErrorEvent,
    EventDropped,
    decode_line,
    encode_line,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
VALID_LINES = (REPO_ROOT / "protocol/examples/v1-events.ndjson").read_bytes().splitlines()
MALFORMED_LINES = (REPO_ROOT / "protocol/examples/v1-malformed.ndjson").read_bytes().splitlines()

# Ordered to match the committed file; the Swift suite asserts the identical
# sequence so both decoders classify alike.
EXPECTED_MALFORMED_REASONS = [
    DropReason.MALFORMED_JSON,
    DropReason.MALFORMED_JSON,
    DropReason.UNSUPPORTED_VERSION,
    DropReason.UNKNOWN_EVENT,
    DropReason.INVALID_PAYLOAD,
    DropReason.INVALID_PAYLOAD,
    DropReason.MISSING_REQUEST_ID,
    DropReason.INVALID_ENVELOPE,
    DropReason.INVALID_ENVELOPE,
]


def test_example_file_shape() -> None:
    assert len(VALID_LINES) == 14, "example file changed without updating tests"
    assert len(MALFORMED_LINES) == len(EXPECTED_MALFORMED_REASONS)


def test_valid_examples_round_trip_losslessly() -> None:
    for line in VALID_LINES:
        envelope = decode_line(line)
        second = decode_line(encode_line(envelope))
        assert envelope == second, f"lossy round trip for {line!r}"


def test_examples_cover_every_event() -> None:
    seen = {decode_line(line).event for line in VALID_LINES}
    assert seen == set(PAYLOAD_TYPES)


def test_extreme_unsigned_values_survive() -> None:
    envelope = decode_line(VALID_LINES[-1])
    assert envelope.ts == 2**64 - 1
    assert envelope.payload.kv_cache_bytes == 2**64 - 1
    assert envelope.payload.output_tokens == 2**32 - 1


def test_malformed_lines_drop_with_expected_reasons() -> None:
    counter = DropCounter()
    for index, line in enumerate(MALFORMED_LINES):
        with pytest.raises(EventDropped) as excinfo:
            decode_line(line)
        counter.record(excinfo.value.reason)
        assert excinfo.value.reason == EXPECTED_MALFORMED_REASONS[index], f"line {index + 1}"
    assert counter.total == len(EXPECTED_MALFORMED_REASONS)
    assert counter.by_reason["malformed_json"] == 2
    assert counter.by_reason["invalid_payload"] == 2
    assert counter.by_reason["invalid_envelope"] == 2


def test_oversized_line_rejected_before_parsing() -> None:
    with pytest.raises(EventDropped) as excinfo:
        decode_line(b"a" * (MAX_LINE_BYTES + 1))
    assert excinfo.value.reason == DropReason.OVERSIZED_LINE


def test_encoder_omits_none_request_id() -> None:
    envelope = Envelope(ts=1, run_id="r-x", payload=ErrorEvent(code="c", message="m"))
    encoded = encode_line(envelope)
    assert b"requestId" not in encoded
    assert encoded.endswith(b"}")  # framing belongs to the NDJSON writer
