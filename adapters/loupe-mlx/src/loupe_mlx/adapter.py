"""The M1.3 instrumentation API: wrap mlx-lm load/generate calls and stream
current-protocol events to the Loupe app's user-owned Unix socket.

Usage:

    from loupe_mlx import LoupeInstrument

    loupe = LoupeInstrument()
    model, tokenizer = loupe.load("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    for response in loupe.stream_generate(model, tokenizer, prompt="..."):
        ...
    loupe.close()

Instrumentation must be invisible to the generation loop: the live socket
sink is a non-blocking queue put with counted drops (see socket_writer), the
recorder/bench file sink flushes locally on each event. Measure its overhead
separately; warmup does not remove per-event I/O. The generator yields mlx-lm's
responses unchanged.
"""

from __future__ import annotations

import os
import threading
import uuid
from collections.abc import Callable
from typing import Any, Iterator

from . import events as ev
from .socket_writer import SocketEventWriter
from .timebase import now_ns

DEFAULT_SOCKET_PATH = os.path.expanduser("~/Library/Application Support/Loupe/runtime/adapter.sock")

__version__ = "0.2.1"


class LoupeInstrument:
    def __init__(
        self,
        socket_path: str | None = None,
        run_id: str | None = None,
        runtime: str = "mlx",
        writer: object | None = None,
        clock: Callable[[], int] = now_ns,
    ) -> None:
        self.run_id = run_id or os.environ.get("LOUPE_RUN_ID") or f"r-{uuid.uuid4().hex[:8]}"
        if not 1 <= len(self.run_id) <= 128:
            raise ValueError("run_id must contain 1 to 128 characters")
        if not runtime or len(runtime) > 128:
            raise ValueError("runtime must contain 1 to 128 characters")
        # One instrumentation loop, pluggable sinks: the live adapter streams
        # to the user app socket, the recorder and bench write files.
        resolved_socket = socket_path or os.environ.get("LOUPE_SOCKET_PATH") or DEFAULT_SOCKET_PATH
        self._writer = writer if writer is not None else SocketEventWriter(resolved_socket)
        self._clock = clock
        self._request_counter = 0
        # A logical run can survive an adapter process relaunch. Include a
        # per-instance nonce so the restarted counter cannot reuse request
        # identifiers already persisted under the same LOUPE_RUN_ID.
        self._request_namespace = uuid.uuid4().hex
        self._state_lock = threading.RLock()
        # mlx-lm model operations are not made thread-safe by instrumentation.
        # Reject overlap deterministically and keep one request lifecycle in
        # sequence/timestamp order instead of emitting interleaved lies.
        self._operation_active = False
        self._sequence = 0
        self._closed = False
        self._close_requested = False
        self._last_emitted_ts = 0
        self._emit(
            ev.SessionStart(
                adapter="loupe-mlx",
                adapter_version=__version__,
                runtime=runtime,
                pid=os.getpid(),
            )
        )
        # Adapter and app read the same mach_continuous clock, so the
        # NTP exchange is degenerate: offset 0 with zero uncertainty. The
        # event still flows so multi-clock adapters stay wire-compatible.
        now = self._clock()
        self._emit(ev.ClockSync(t0=now, t1=now, t2=now, t3=now), at_ns=now)

    @property
    def dropped_events(self) -> int:
        return self._writer.dropped

    @property
    def connected(self) -> bool:
        return self._writer.connected

    def load(self, model_id: str, **kwargs: Any) -> tuple[Any, Any]:
        self._begin_operation()
        try:
            import mlx.core as mx
            from mlx_lm import load

            event_model_id = str(model_id)[:1024] or "unknown"
            self._emit(ev.ModelLoadStart(model_id=event_model_id))
            try:
                model, tokenizer = load(model_id, **kwargs)
            except Exception as exc:
                # Runtime exceptions commonly contain model cache paths, URLs,
                # or credentials. Preserve the useful category, never the text.
                self._emit(
                    ev.ErrorEvent(
                        code="model_load_failed",
                        message=f"Model load failed ({type(exc).__name__})",
                    )
                )
                self._emit(ev.ModelLoadEnd(model_id=event_model_id, ok=False))
                raise
            self._emit(
                ev.ModelLoadEnd(
                    model_id=event_model_id,
                    ok=True,
                    weights_bytes=max(0, int(mx.get_active_memory())),
                )
            )
            return model, tokenizer
        finally:
            self._end_operation()

    def stream_generate(
        self, model: Any, tokenizer: Any, prompt: Any, **kwargs: Any
    ) -> Iterator[Any]:
        self._begin_operation()
        try:
            import mlx.core as mx
            from mlx_lm import stream_generate

            with self._state_lock:
                self._request_counter += 1
                request_id = f"q-{self._request_namespace}-{self._request_counter}"
            active_at_start = max(0, int(mx.get_active_memory()))
            request_start_ns = self._clock()
            self._emit(ev.RequestStart(), request_id, at_ns=request_start_ns)

            produced = 0
            finish_reason = "stop"
            prefill_done = False
            decode_start_ns: int | None = None
            last_response_at_ns: int | None = None
            caller_progress = kwargs.get("prompt_progress_callback")

            def prompt_progress(processed: int, total: int) -> None:
                nonlocal prefill_done, decode_start_ns
                # mlx-lm evaluates all but the final prompt token in its prefill
                # loop. This callback observes that boundary directly; the final
                # prompt token's forward pass belongs to our first-token window.
                if not prefill_done and total > 0 and processed == total - 1:
                    decode_start_ns = self._clock()
                    self._emit(
                        ev.PrefillEnd(prompt_tokens=total), request_id, at_ns=decode_start_ns
                    )
                    prefill_done = True
                if caller_progress is not None:
                    caller_progress(processed, total)

            kwargs["prompt_progress_callback"] = prompt_progress
            try:
                for response in stream_generate(model, tokenizer, prompt=prompt, **kwargs):
                    response_at_ns = self._clock()
                    last_response_at_ns = response_at_ns
                    if not prefill_done:
                        # A runtime path without progress callbacks (e.g. draft
                        # generation) supplies only an observed upper bound. Do
                        # not manufacture decode time from prompt_tps: that clock
                        # excludes host setup and includes first-token evaluation.
                        prompt_tokens = int(getattr(response, "prompt_tokens", 0) or 0)
                        self._emit(
                            ev.PrefillEnd(prompt_tokens=prompt_tokens),
                            request_id,
                            at_ns=response_at_ns,
                        )
                        prefill_done = True
                    produced += 1
                    active_now = max(0, int(mx.get_active_memory()))
                    self._emit(
                        ev.DecodeTick(
                            output_tokens=produced,
                            active_memory_bytes=active_now,
                            allocator_memory_growth_bytes=max(0, active_now - active_at_start),
                            memory_provenance=ev.MemoryMetricProvenance.ALLOCATOR_DELTA_PROXY,
                        ),
                        request_id,
                        at_ns=response_at_ns,
                    )
                    raw_finish_reason = getattr(response, "finish_reason", None)
                    if raw_finish_reason:
                        candidate = str(raw_finish_reason).lower()
                        finish_reason = (
                            candidate
                            if candidate in {"stop", "length", "eos", "cancelled"}
                            else "other"
                        )
                    yield response
            except GeneratorExit:
                self._finish_request(
                    request_id=request_id,
                    output_tokens=produced,
                    finish_reason="cancelled",
                    decode_start_ns=decode_start_ns,
                    # Closing a Python generator happens after control was
                    # yielded to the consumer. Use the last runtime response
                    # receipt, not consumer think time, as the decode boundary.
                    ended_at_ns=last_response_at_ns,
                )
                raise
            except Exception as exc:
                failure_at_ns = self._clock()
                self._emit(
                    ev.ErrorEvent(
                        code="generation_failed",
                        message=f"Generation failed ({type(exc).__name__})",
                    ),
                    request_id,
                    at_ns=failure_at_ns,
                )
                self._finish_request(
                    request_id=request_id,
                    output_tokens=produced,
                    finish_reason="error",
                    decode_start_ns=decode_start_ns,
                    ended_at_ns=failure_at_ns,
                )
                raise
            self._finish_request(
                request_id=request_id,
                output_tokens=produced,
                finish_reason=finish_reason,
                decode_start_ns=decode_start_ns,
                ended_at_ns=last_response_at_ns,
            )
        finally:
            self._end_operation()

    def close(self) -> None:
        with self._state_lock:
            if self._closed:
                return
            # Mark shutdown pending before inspecting operation state. A begin,
            # end, and close can therefore never pass each other between an
            # operation-lock probe and a later state update.
            self._close_requested = True
            operation_active = self._operation_active
        if operation_active:
            # Calling close between generator yields must not deadlock the
            # caller. The active request emits request_end first and its
            # finally block publishes the terminal transport summary.
            return
        self._close_transport()

    def _close_transport(self) -> None:
        with self._state_lock:
            if self._closed:
                return
            self._closed = True
            self._close_requested = False
            # If this terminal event reaches the app, the producer-side drop count
            # is exact for every preceding application event. If it does not,
            # sequence gaps remain a lower bound and the app reports "unknown".
            attempted = self._sequence
            self._sequence += 1
            terminal_sequence = self._sequence
            terminal_ts = max(self._last_emitted_ts, self._clock())
            self._last_emitted_ts = terminal_ts

        def terminal(dropped: int) -> ev.Envelope:
            return ev.Envelope(
                ts=terminal_ts,
                run_id=self.run_id,
                payload=ev.TransportSummary(
                    attempted_events=attempted,
                    producer_dropped_events=max(0, int(dropped)),
                ),
                seq=terminal_sequence,
            )

        finish = getattr(self._writer, "finish", None)
        if callable(finish):
            finish(terminal)
        else:
            # Custom synchronous sinks have no background drain that can
            # change their counter between this read and the emit.
            self._writer.emit(terminal(self._writer.dropped))
            self._writer.close()

    def _begin_operation(self) -> None:
        with self._state_lock:
            if self._closed or self._close_requested:
                raise RuntimeError("LoupeInstrument is closed")
            if self._operation_active:
                raise RuntimeError("LoupeInstrument supports one active model operation")
            self._operation_active = True

    def _end_operation(self) -> None:
        with self._state_lock:
            self._operation_active = False
            should_close = self._close_requested and not self._closed
        if should_close:
            self._close_transport()

    def _finish_request(
        self,
        *,
        request_id: str,
        output_tokens: int,
        finish_reason: str,
        decode_start_ns: int | None,
        ended_at_ns: int | None = None,
    ) -> None:
        ended_at_ns = ended_at_ns if ended_at_ns is not None else self._clock()
        duration = None
        if output_tokens > 0 and decode_start_ns is not None and ended_at_ns > decode_start_ns:
            duration = min(ended_at_ns - decode_start_ns, ev.MAX_UINT64)
        self._emit(
            ev.RequestEnd(
                output_tokens=output_tokens,
                finish_reason=finish_reason,
                decode_duration_ns=duration,
            ),
            request_id,
            at_ns=ended_at_ns,
        )

    def _emit(
        self,
        payload: Any,
        request_id: str | None = None,
        *,
        at_ns: int | None = None,
    ) -> None:
        with self._state_lock:
            if self._closed:
                return
            timestamp = at_ns if at_ns is not None else self._clock()
            timestamp = max(self._last_emitted_ts, timestamp)
            self._last_emitted_ts = timestamp
            self._sequence += 1
            self._writer.emit(
                ev.Envelope(
                    ts=timestamp,
                    run_id=self.run_id,
                    payload=payload,
                    request_id=request_id,
                    seq=self._sequence,
                )
            )
