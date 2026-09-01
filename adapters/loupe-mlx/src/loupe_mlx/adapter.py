"""The M1.3 instrumentation API: wrap mlx-lm load/generate calls and stream
protocol-v1 events to the Loupe app's user-owned Unix socket.

Usage:

    from loupe_mlx import LoupeInstrument

    loupe = LoupeInstrument()
    model, tokenizer = loupe.load("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    for response in loupe.stream_generate(model, tokenizer, prompt="..."):
        ...
    loupe.close()

Instrumentation must be invisible to the generation loop: the live socket
sink is a non-blocking queue put with counted drops (see socket_writer), the
recorder/bench file sink is a local flush whose cost the harness's warmup
absorbs, and the generator yields mlx-lm's responses unchanged.
"""

from __future__ import annotations

import os
import uuid
from typing import Any, Iterator

from . import events as ev
from .socket_writer import SocketEventWriter
from .timebase import now_ns

DEFAULT_SOCKET_PATH = os.path.expanduser("~/Library/Application Support/Loupe/runtime/adapter.sock")

__version__ = "0.2.0"


class LoupeInstrument:
    def __init__(
        self,
        socket_path: str | None = None,
        run_id: str | None = None,
        runtime: str = "mlx",
        writer: object | None = None,
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
        self._request_counter = 0
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
        now = now_ns()
        self._emit(ev.ClockSync(t0=now, t1=now, t2=now, t3=now))

    @property
    def dropped_events(self) -> int:
        return self._writer.dropped

    @property
    def connected(self) -> bool:
        return self._writer.connected

    def load(self, model_id: str, **kwargs: Any) -> tuple[Any, Any]:
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

    def stream_generate(
        self, model: Any, tokenizer: Any, prompt: Any, **kwargs: Any
    ) -> Iterator[Any]:
        import mlx.core as mx
        from mlx_lm import stream_generate

        self._request_counter += 1
        request_id = f"q-{self._request_counter}"
        active_at_start = max(0, int(mx.get_active_memory()))
        self._emit(ev.RequestStart(), request_id)

        produced = 0
        finish_reason = "stop"
        prefill_done = False
        try:
            for response in stream_generate(model, tokenizer, prompt=prompt, **kwargs):
                if not prefill_done:
                    prompt_tokens = int(getattr(response, "prompt_tokens", 0) or 0)
                    self._emit(ev.PrefillEnd(prompt_tokens=prompt_tokens), request_id)
                    prefill_done = True
                produced += 1
                active_now = max(0, int(mx.get_active_memory()))
                self._emit(
                    ev.DecodeTick(
                        output_tokens=produced,
                        # KV growth over the request baseline; the runtime has
                        # no direct KV-size counter.
                        kv_cache_bytes=max(0, active_now - active_at_start),
                        active_memory_bytes=active_now,
                    ),
                    request_id,
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
            self._emit(
                ev.RequestEnd(output_tokens=produced, finish_reason="cancelled"),
                request_id,
            )
            raise
        except Exception as exc:
            self._emit(
                ev.ErrorEvent(
                    code="generation_failed",
                    message=f"Generation failed ({type(exc).__name__})",
                ),
                request_id,
            )
            self._emit(ev.RequestEnd(output_tokens=produced, finish_reason="error"), request_id)
            raise
        self._emit(
            ev.RequestEnd(output_tokens=produced, finish_reason=finish_reason),
            request_id,
        )

    def close(self) -> None:
        self._writer.close()

    def _emit(self, payload: Any, request_id: str | None = None) -> None:
        self._writer.emit(
            ev.Envelope(ts=now_ns(), run_id=self.run_id, payload=payload, request_id=request_id)
        )
