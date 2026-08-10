"""Fixture recorder: a real mlx-lm session written as protocol-v1 events.

A thin loop over the same `LoupeInstrument` the live adapter uses, pointed at
a file sink — recorder events and adapter events cannot drift apart because
they come from the same code.
"""

from __future__ import annotations

import argparse
import itertools
import sys
import uuid

from .adapter import LoupeInstrument
from .socket_writer import FileEventWriter
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


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        import mlx_lm  # noqa: F401
    except ImportError:
        print("mlx-lm is not installed; run `make bootstrap-mlx` first.", file=sys.stderr)
        return 2

    loupe = LoupeInstrument(
        run_id=args.run_id or f"r-{uuid.uuid4().hex[:8]}",
        writer=FileEventWriter(args.out),
    )
    try:
        model, tokenizer = loupe.load(args.model)
    except Exception:
        loupe.close()
        return 1

    deadline = now_ns() + int(args.duration * 1_000_000_000)
    for prompt in itertools.cycle(PROMPTS):
        if now_ns() >= deadline:
            break
        try:
            for _ in loupe.stream_generate(model, tokenizer, prompt, max_tokens=args.max_tokens):
                pass
        except Exception:
            # The instrument already recorded the error and request_end;
            # a recorder keeps recording.
            continue
    loupe.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
