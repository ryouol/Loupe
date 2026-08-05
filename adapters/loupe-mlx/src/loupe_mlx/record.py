"""Fixture recorder: a real mlx-lm session written as protocol-v1 events.

Not the M1.3 adapter — no socket, no buffering thread. mlx-lm imports lazily
so CI never needs it; install the ``mlx`` extra to record.
"""

from __future__ import annotations

import argparse
import itertools
import os
import sys
import uuid
from typing import Any, BinaryIO

from . import events as ev
from .timebase import now_ns

# Varied lengths on purpose: prefill variety is the point of a baseline.
PROMPTS = [
    "Explain the difference between prefill and decode in LLM inference.",
    "Write a haiku about memory bandwidth.",
    "List three reasons profilers lie about RSS on macOS, briefly.",
    "Summarize in two sentences why KV cache size grows linearly with context "
    "length, and what that means for batch serving on a laptop with unified "
    "memory shared between the CPU and the GPU.",
    "What is a thermal state change?",
    "Describe, step by step, how a token flows through a transformer during "
    "autoregressive decoding: embedding lookup, attention against the KV "
    "cache, the MLP, and the final projection back to logits.",
]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="loupe_mlx.record",
        description="Record a real mlx-lm session as protocol-v1 NDJSON events.",
    )
    parser.add_argument("--model", required=True, help="HF repo id or local path")
    parser.add_argument("--out", required=True, help="output .ndjson path")
    parser.add_argument("--duration", type=float, default=60.0, help="seconds")
    parser.add_argument("--max-tokens", type=int, default=200)
    parser.add_argument("--run-id", default=None)
    return parser


def _emit(fh: BinaryIO, envelope: ev.Envelope) -> None:
    fh.write(ev.encode_line(envelope))
    fh.write(b"\n")
    fh.flush()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        import mlx.core as mx
        from mlx_lm import load, stream_generate
    except ImportError:
        print(
            "mlx-lm is not installed; run `make bootstrap-mlx` first.",
            file=sys.stderr,
        )
        return 2

    run_id = args.run_id or f"r-{uuid.uuid4().hex[:8]}"

    def envelope(payload: Any, request_id: str | None = None) -> ev.Envelope:
        return ev.Envelope(ts=now_ns(), run_id=run_id, payload=payload, request_id=request_id)

    with open(args.out, "wb") as fh:
        _emit(
            fh,
            envelope(
                ev.SessionStart(
                    adapter="loupe-mlx-recorder",
                    adapter_version="0.0.1",
                    runtime="mlx",
                    pid=os.getpid(),
                )
            ),
        )
        _emit(fh, envelope(ev.ModelLoadStart(model_id=args.model)))
        try:
            model, tokenizer = load(args.model)
        except Exception as exc:  # noqa: BLE001 - recorded, not swallowed
            _emit(fh, envelope(ev.ErrorEvent(code="model_load_failed", message=str(exc)[:4000])))
            _emit(fh, envelope(ev.ModelLoadEnd(model_id=args.model, ok=False)))
            return 1
        _emit(
            fh,
            envelope(
                ev.ModelLoadEnd(
                    model_id=args.model, ok=True, weights_bytes=int(mx.get_active_memory())
                )
            ),
        )

        deadline = now_ns() + int(args.duration * 1_000_000_000)
        for index, prompt in enumerate(itertools.cycle(PROMPTS), start=1):
            if now_ns() >= deadline:
                break
            request_id = f"q-{index}"
            # KV size ≈ active-memory growth over the request baseline —
            # honestly derived, properly computed later by the M1.3 adapter.
            active_at_start = int(mx.get_active_memory())
            _emit(fh, envelope(ev.RequestStart(), request_id))
            produced = 0
            finish_reason = "stop"
            prefill_done = False
            try:
                for response in stream_generate(
                    model, tokenizer, prompt=prompt, max_tokens=args.max_tokens
                ):
                    if not prefill_done:
                        prompt_tokens = int(getattr(response, "prompt_tokens", 0) or 0)
                        _emit(fh, envelope(ev.PrefillEnd(prompt_tokens=prompt_tokens), request_id))
                        prefill_done = True
                    produced += 1
                    active_now = int(mx.get_active_memory())
                    _emit(
                        fh,
                        envelope(
                            ev.DecodeTick(
                                output_tokens=produced,
                                kv_cache_bytes=max(0, active_now - active_at_start),
                                active_memory_bytes=active_now,
                            ),
                            request_id,
                        ),
                    )
                    finish_reason = getattr(response, "finish_reason", None) or finish_reason
            except Exception as exc:  # noqa: BLE001 - recorded, not swallowed
                _emit(
                    fh,
                    envelope(
                        ev.ErrorEvent(code="generation_failed", message=str(exc)[:4000]),
                        request_id,
                    ),
                )
                finish_reason = "error"
            _emit(
                fh,
                envelope(
                    ev.RequestEnd(output_tokens=produced, finish_reason=finish_reason),
                    request_id,
                ),
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
