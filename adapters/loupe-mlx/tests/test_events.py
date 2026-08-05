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


def test_example_file_shape(valid_lines, malformed_lines) -> None:
    assert len(valid_lines) == 14, "example file changed without updating tests"
    assert len(malformed_lines) == len(EXPECTED_MALFORMED_REASONS)


def test_valid_examples_round_trip_losslessly(valid_lines) -> None:
    for line in valid_lines:
        envelope = decode_line(line)
        second = decode_line(encode_line(envelope))
        assert envelope == second, f"lossy round trip for {line!r}"


def test_examples_cover_every_event(valid_lines) -> None:
    seen = {decode_line(line).event for line in valid_lines}
    assert seen == set(PAYLOAD_TYPES)


def test_extreme_unsigned_values_survive(valid_lines) -> None:
    envelope = decode_line(valid_lines[-1])
    assert envelope.ts == 2**64 - 1
    assert envelope.payload.kv_cache_bytes == 2**64 - 1
    assert envelope.payload.output_tokens == 2**32 - 1


def test_malformed_lines_drop_with_expected_reasons(malformed_lines) -> None:
    counter = DropCounter()
    for index, line in enumerate(malformed_lines):
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


def test_line_cap_matches_schema(schema) -> None:
    assert MAX_LINE_BYTES == schema["x-limits"]["maxLineBytes"]


def test_encoder_omits_none_request_id() -> None:
    envelope = Envelope(ts=1, run_id="r-x", payload=ErrorEvent(code="c", message="m"))
    encoded = encode_line(envelope)
    assert b"requestId" not in encoded
    assert encoded.endswith(b"}")  # framing belongs to the NDJSON writer
