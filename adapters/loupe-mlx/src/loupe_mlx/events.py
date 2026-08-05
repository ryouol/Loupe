"""Event protocol v1 — Python mirror of ``protocol/events.schema.json``.

Hand-written to match the Swift types in ``Sources/LoupeCore/Protocol``.
Drift between the two is caught by tests that round-trip the same committed
example file in both languages and validate it against the schema. Changing
the contract means bumping the version, updating fixtures, and updating every
adapter in the same commit.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, ClassVar, Union

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 65536


class DropReason(str, Enum):
    """Labels are shared verbatim with the Swift ``EventDropReason``."""

    OVERSIZED_LINE = "oversized_line"
    MALFORMED_JSON = "malformed_json"
    UNSUPPORTED_VERSION = "unsupported_version"
    UNKNOWN_EVENT = "unknown_event"
    INVALID_ENVELOPE = "invalid_envelope"
    INVALID_PAYLOAD = "invalid_payload"
    MISSING_REQUEST_ID = "missing_request_id"


class EventDropped(Exception):
    """The one exception ``decode_line`` raises; adapters are untrusted, so
    every malformed shape becomes a reason + counter bump, never a crash."""

    def __init__(self, reason: DropReason, detail: str = "") -> None:
        super().__init__(f"{reason.value}: {detail}" if detail else reason.value)
        self.reason = reason
        self.detail = detail


class DropCounter:
    def __init__(self) -> None:
        self.total = 0
        self.by_reason: dict[str, int] = {}

    def record(self, reason: DropReason) -> None:
        self.total += 1
        self.by_reason[reason.value] = self.by_reason.get(reason.value, 0) + 1


def _payload_error(detail: str) -> EventDropped:
    return EventDropped(DropReason.INVALID_PAYLOAD, detail)


def _req_str(obj: dict[str, Any], key: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str):
        raise _payload_error(f"{key} must be a string")
    return value


def _req_uint(obj: dict[str, Any], key: str) -> int:
    value = obj.get(key)
    # bool is an int subclass; True would otherwise pass as 1.
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise _payload_error(f"{key} must be a non-negative integer")
    return value


def _opt_uint(obj: dict[str, Any], key: str) -> int | None:
    if key not in obj or obj[key] is None:
        return None
    return _req_uint(obj, key)


def _req_bool(obj: dict[str, Any], key: str) -> bool:
    value = obj.get(key)
    if not isinstance(value, bool):
        raise _payload_error(f"{key} must be a boolean")
    return value


@dataclass(frozen=True, slots=True)
class SessionStart:
    EVENT: ClassVar[str] = "session_start"
    adapter: str
    adapter_version: str
    runtime: str
    pid: int

    def to_json_payload(self) -> dict[str, Any]:
        return {
            "adapter": self.adapter,
            "adapterVersion": self.adapter_version,
            "runtime": self.runtime,
            "pid": self.pid,
        }

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "SessionStart":
        return cls(
            adapter=_req_str(obj, "adapter"),
            adapter_version=_req_str(obj, "adapterVersion"),
            runtime=_req_str(obj, "runtime"),
            pid=_req_uint(obj, "pid"),
        )


@dataclass(frozen=True, slots=True)
class ClockSync:
    EVENT: ClassVar[str] = "clock_sync"
    t0: int
    t1: int
    t2: int
    t3: int

    def to_json_payload(self) -> dict[str, Any]:
        return {"t0": self.t0, "t1": self.t1, "t2": self.t2, "t3": self.t3}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "ClockSync":
        return cls(
            t0=_req_uint(obj, "t0"),
            t1=_req_uint(obj, "t1"),
            t2=_req_uint(obj, "t2"),
            t3=_req_uint(obj, "t3"),
        )


@dataclass(frozen=True, slots=True)
class ModelLoadStart:
    EVENT: ClassVar[str] = "model_load_start"
    model_id: str

    def to_json_payload(self) -> dict[str, Any]:
        return {"modelId": self.model_id}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "ModelLoadStart":
        return cls(model_id=_req_str(obj, "modelId"))


@dataclass(frozen=True, slots=True)
class ModelLoadEnd:
    EVENT: ClassVar[str] = "model_load_end"
    model_id: str
    ok: bool
    weights_bytes: int | None = None

    def to_json_payload(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"modelId": self.model_id, "ok": self.ok}
        if self.weights_bytes is not None:
            payload["weightsBytes"] = self.weights_bytes
        return payload

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "ModelLoadEnd":
        return cls(
            model_id=_req_str(obj, "modelId"),
            ok=_req_bool(obj, "ok"),
            weights_bytes=_opt_uint(obj, "weightsBytes"),
        )


@dataclass(frozen=True, slots=True)
class RequestStart:
    EVENT: ClassVar[str] = "request_start"
    prompt_tokens: int | None = None

    def to_json_payload(self) -> dict[str, Any]:
        if self.prompt_tokens is None:
            return {}
        return {"promptTokens": self.prompt_tokens}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "RequestStart":
        return cls(prompt_tokens=_opt_uint(obj, "promptTokens"))


@dataclass(frozen=True, slots=True)
class PrefillEnd:
    EVENT: ClassVar[str] = "prefill_end"
    prompt_tokens: int

    def to_json_payload(self) -> dict[str, Any]:
        return {"promptTokens": self.prompt_tokens}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "PrefillEnd":
        return cls(prompt_tokens=_req_uint(obj, "promptTokens"))


@dataclass(frozen=True, slots=True)
class DecodeTick:
    EVENT: ClassVar[str] = "decode_tick"
    output_tokens: int
    kv_cache_bytes: int
    active_memory_bytes: int

    def to_json_payload(self) -> dict[str, Any]:
        return {
            "outputTokens": self.output_tokens,
            "kvCacheBytes": self.kv_cache_bytes,
            "activeMemoryBytes": self.active_memory_bytes,
        }

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "DecodeTick":
        return cls(
            output_tokens=_req_uint(obj, "outputTokens"),
            kv_cache_bytes=_req_uint(obj, "kvCacheBytes"),
            active_memory_bytes=_req_uint(obj, "activeMemoryBytes"),
        )


@dataclass(frozen=True, slots=True)
class RequestEnd:
    EVENT: ClassVar[str] = "request_end"
    output_tokens: int
    finish_reason: str

    def to_json_payload(self) -> dict[str, Any]:
        return {"outputTokens": self.output_tokens, "finishReason": self.finish_reason}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "RequestEnd":
        return cls(
            output_tokens=_req_uint(obj, "outputTokens"),
            finish_reason=_req_str(obj, "finishReason"),
        )


@dataclass(frozen=True, slots=True)
class ErrorEvent:
    EVENT: ClassVar[str] = "error"
    code: str
    message: str

    def to_json_payload(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "ErrorEvent":
        return cls(code=_req_str(obj, "code"), message=_req_str(obj, "message"))


Payload = Union[
    SessionStart,
    ClockSync,
    ModelLoadStart,
    ModelLoadEnd,
    RequestStart,
    PrefillEnd,
    DecodeTick,
    RequestEnd,
    ErrorEvent,
]

PAYLOAD_TYPES: dict[str, type] = {
    cls.EVENT: cls
    for cls in (
        SessionStart,
        ClockSync,
        ModelLoadStart,
        ModelLoadEnd,
        RequestStart,
        PrefillEnd,
        DecodeTick,
        RequestEnd,
        ErrorEvent,
    )
}

# Request-scoped events are meaningless without a request id.
REQUEST_SCOPED_EVENTS = frozenset(
    {"request_start", "prefill_end", "decode_tick", "request_end"}
)


@dataclass(frozen=True, slots=True)
class Envelope:
    ts: int
    run_id: str
    payload: Payload
    request_id: str | None = None
    v: int = field(default=PROTOCOL_VERSION)

    @property
    def event(self) -> str:
        return type(self.payload).EVENT


def encode_line(envelope: Envelope) -> bytes:
    """One JSON object, no trailing newline — the NDJSON writer owns framing.
    Sorted keys keep recorded fixtures diffable."""
    obj: dict[str, Any] = {
        "v": envelope.v,
        "ts": envelope.ts,
        "runId": envelope.run_id,
        "event": envelope.event,
        "payload": envelope.payload.to_json_payload(),
    }
    if envelope.request_id is not None:
        obj["requestId"] = envelope.request_id
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def decode_line(raw: bytes | str) -> Envelope:
    """Mirrors the Swift decoder's classification exactly, including the quirk
    that a non-integer ``v`` reads as malformed (the Swift probe can't see it)."""
    data = raw.encode("utf-8") if isinstance(raw, str) else raw
    if len(data) > MAX_LINE_BYTES:
        raise EventDropped(DropReason.OVERSIZED_LINE, f"{len(data)} bytes")

    try:
        obj = json.loads(data)
    except (ValueError, UnicodeDecodeError) as exc:
        raise EventDropped(DropReason.MALFORMED_JSON, str(exc)) from None
    if not isinstance(obj, dict):
        raise EventDropped(DropReason.MALFORMED_JSON, "envelope is not an object")

    version = obj.get("v")
    if version is not None and (not isinstance(version, int) or isinstance(version, bool)):
        raise EventDropped(DropReason.MALFORMED_JSON, "v is not an integer")
    if version is None:
        raise EventDropped(DropReason.INVALID_ENVELOPE, "missing v")
    if version != PROTOCOL_VERSION:
        raise EventDropped(DropReason.UNSUPPORTED_VERSION, str(version))

    event = obj.get("event")
    if event is not None and not isinstance(event, str):
        raise EventDropped(DropReason.MALFORMED_JSON, "event is not a string")
    if event is None:
        raise EventDropped(DropReason.INVALID_ENVELOPE, "missing event")
    payload_type = PAYLOAD_TYPES.get(event)
    if payload_type is None:
        raise EventDropped(DropReason.UNKNOWN_EVENT, event)

    ts = obj.get("ts")
    if not isinstance(ts, int) or isinstance(ts, bool) or ts < 0:
        raise EventDropped(DropReason.INVALID_ENVELOPE, "ts")
    run_id = obj.get("runId")
    if not isinstance(run_id, str):
        raise EventDropped(DropReason.INVALID_ENVELOPE, "runId")
    request_id = obj.get("requestId")
    if request_id is not None and not isinstance(request_id, str):
        raise EventDropped(DropReason.INVALID_ENVELOPE, "requestId")

    payload_obj = obj.get("payload")
    if not isinstance(payload_obj, dict):
        raise EventDropped(DropReason.INVALID_PAYLOAD, "payload is not an object")
    payload = payload_type.from_json_payload(payload_obj)

    if event in REQUEST_SCOPED_EVENTS and request_id is None:
        raise EventDropped(DropReason.MISSING_REQUEST_ID, event)

    return Envelope(ts=ts, run_id=run_id, payload=payload, request_id=request_id)
