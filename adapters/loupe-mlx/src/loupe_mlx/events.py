"""Event protocol v1 — Python mirror of ``protocol/events.schema.json``.

Drift against the Swift types is caught by cross-language round-trip and
schema-conformance tests over the same committed examples.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, ClassVar, Union, get_args

PROTOCOL_VERSION = 1
# Shared with the schema (x-limits.maxLineBytes) and the Swift decoder;
# conformance tests in both languages pin the three together.
MAX_LINE_BYTES = 65536
MAX_UINT32 = 2**32 - 1
MAX_UINT64 = 2**64 - 1
MAX_PID = 2**31 - 1


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
    """The one exception ``decode_line`` raises: a reason, never a crash."""

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


def _bounded_str(obj: dict[str, Any], key: str, maximum: int, *, allow_empty: bool = False) -> str:
    value = _req_str(obj, key)
    if (not allow_empty and not value) or len(value) > maximum:
        raise _payload_error(f"{key} length")
    return value


def _reject_extra_keys(obj: dict[str, Any], allowed: set[str]) -> None:
    if not set(obj).issubset(allowed):
        raise _payload_error("unknown field")


def _req_uint(obj: dict[str, Any], key: str, maximum: int = MAX_UINT64) -> int:
    value = obj.get(key)
    # bool is an int subclass; True would otherwise pass as 1.
    if not isinstance(value, int) or isinstance(value, bool) or value < 0 or value > maximum:
        raise _payload_error(f"{key} must be an unsigned integer up to {maximum}")
    return value


def _opt_uint(obj: dict[str, Any], key: str, maximum: int = MAX_UINT64) -> int | None:
    if key not in obj or obj[key] is None:
        return None
    return _req_uint(obj, key, maximum)


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
        _reject_extra_keys(obj, {"adapter", "adapterVersion", "runtime", "pid"})
        pid = _req_uint(obj, "pid", MAX_PID)
        if pid == 0:
            raise _payload_error("pid")
        return cls(
            adapter=_bounded_str(obj, "adapter", 256),
            adapter_version=_bounded_str(obj, "adapterVersion", 128),
            runtime=_bounded_str(obj, "runtime", 128),
            pid=pid,
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
        _reject_extra_keys(obj, {"t0", "t1", "t2", "t3"})
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
        _reject_extra_keys(obj, {"modelId"})
        return cls(model_id=_bounded_str(obj, "modelId", 1024))


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
        _reject_extra_keys(obj, {"modelId", "ok", "weightsBytes"})
        return cls(
            model_id=_bounded_str(obj, "modelId", 1024),
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
        _reject_extra_keys(obj, {"promptTokens"})
        return cls(prompt_tokens=_opt_uint(obj, "promptTokens", MAX_UINT32))


@dataclass(frozen=True, slots=True)
class PrefillEnd:
    EVENT: ClassVar[str] = "prefill_end"
    prompt_tokens: int

    def to_json_payload(self) -> dict[str, Any]:
        return {"promptTokens": self.prompt_tokens}

    @classmethod
    def from_json_payload(cls, obj: dict[str, Any]) -> "PrefillEnd":
        _reject_extra_keys(obj, {"promptTokens"})
        return cls(prompt_tokens=_req_uint(obj, "promptTokens", MAX_UINT32))


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
        _reject_extra_keys(obj, {"outputTokens", "kvCacheBytes", "activeMemoryBytes"})
        return cls(
            output_tokens=_req_uint(obj, "outputTokens", MAX_UINT32),
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
        _reject_extra_keys(obj, {"outputTokens", "finishReason"})
        return cls(
            output_tokens=_req_uint(obj, "outputTokens", MAX_UINT32),
            finish_reason=_bounded_str(obj, "finishReason", 64),
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
        _reject_extra_keys(obj, {"code", "message"})
        return cls(
            code=_bounded_str(obj, "code", 128),
            message=_bounded_str(obj, "message", 4096, allow_empty=True),
        )


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

PAYLOAD_TYPES: dict[str, type] = {cls.EVENT: cls for cls in get_args(Payload)}

# Request-scoped events are meaningless without a request id.
REQUEST_SCOPED_EVENTS = frozenset({"request_start", "prefill_end", "decode_tick", "request_end"})


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
    """No trailing newline (the writer owns framing); sorted keys for diffs."""
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
    """Mirrors the Swift decoder's classification for the shared malformed
    corpus. One known divergence: Python rejects numeric-typed fields given
    as whole floats (``"v": 1.0``) where Foundation's JSONDecoder coerces
    them — Python is the stricter side, which only ever drops more."""
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

    if not set(obj).issubset({"v", "ts", "runId", "requestId", "event", "payload"}):
        raise EventDropped(DropReason.INVALID_ENVELOPE, "unknown field")

    ts = obj.get("ts")
    if not isinstance(ts, int) or isinstance(ts, bool) or ts < 0 or ts > MAX_UINT64:
        raise EventDropped(DropReason.INVALID_ENVELOPE, "ts")
    run_id = obj.get("runId")
    if not isinstance(run_id, str) or not 1 <= len(run_id) <= 128:
        raise EventDropped(DropReason.INVALID_ENVELOPE, "runId")
    request_id = obj.get("requestId")
    if request_id is not None and (
        not isinstance(request_id, str) or not 1 <= len(request_id) <= 128
    ):
        raise EventDropped(DropReason.INVALID_ENVELOPE, "requestId")

    payload_obj = obj.get("payload")
    if not isinstance(payload_obj, dict):
        raise EventDropped(DropReason.INVALID_PAYLOAD, "payload is not an object")
    payload = payload_type.from_json_payload(payload_obj)

    if event in REQUEST_SCOPED_EVENTS and request_id is None:
        raise EventDropped(DropReason.MISSING_REQUEST_ID, event)

    return Envelope(ts=ts, run_id=run_id, payload=payload, request_id=request_id)
