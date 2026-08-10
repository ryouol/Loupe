"""One benchmark run: a single request at an exact prompt length, events to a
file. Driven by loupe-bench once per (context x repeat); kept to one request
so every process starts cold-cache-fair with only the model load amortized
away by the harness's warmup runs.
"""

from __future__ import annotations

import argparse
import sys
from typing import BinaryIO

from . import events as ev
from .timebase import now_ns

FILLER = (
    "Local inference turns a laptop into a language model server, and every "
    "token it decodes moves weights through the same unified memory the rest "
    "of the system is using. "
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="loupe_mlx.bench")
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--context-tokens", type=int, required=True)
    parser.add_argument("--max-tokens", type=int, default=64)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--run-id", default="r-bench")
    return parser


def _emit(fh: BinaryIO, run_id: str, payload, request_id: str | None = None) -> None:
    fh.write(
        ev.encode_line(
            ev.Envelope(ts=now_ns(), run_id=run_id, payload=payload, request_id=request_id)
        )
    )
    fh.write(b"\n")


def prompt_of_length(tokenizer, target_tokens: int) -> str:
    """Deterministic prompt truncated to exactly the requested token count."""
    text = FILLER * (target_tokens // 8 + 2)
    ids = tokenizer.encode(text)[:target_tokens]
    return tokenizer.decode(ids)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        import mlx.core as mx
        from mlx_lm import load, stream_generate
    except ImportError:
        print("mlx-lm is not installed; run `make bootstrap-mlx`.", file=sys.stderr)
        return 2

    mx.random.seed(args.seed)
    with open(args.out, "wb") as fh:
        _emit(
            fh,
            args.run_id,
            ev.SessionStart(
                adapter="loupe-mlx-bench", adapter_version="0.1.0", runtime="mlx", pid=0
            ),
        )
        _emit(fh, args.run_id, ev.ModelLoadStart(model_id=args.model))
        model, tokenizer = load(args.model)
        _emit(
            fh,
            args.run_id,
            ev.ModelLoadEnd(
                model_id=args.model, ok=True, weights_bytes=int(mx.get_active_memory())
            ),
        )

        prompt = prompt_of_length(tokenizer, args.context_tokens)
        request_id = "q-1"
        baseline = int(mx.get_active_memory())
        _emit(fh, args.run_id, ev.RequestStart(), request_id)
        produced = 0
        prefill_done = False
        finish = "stop"
        for response in stream_generate(
            model, tokenizer, prompt=prompt, max_tokens=args.max_tokens
        ):
            if not prefill_done:
                _emit(
                    fh,
                    args.run_id,
                    ev.PrefillEnd(
                        prompt_tokens=int(getattr(response, "prompt_tokens", 0) or 0)
                    ),
                    request_id,
                )
                prefill_done = True
            produced += 1
            active = int(mx.get_active_memory())
            _emit(
                fh,
                args.run_id,
                ev.DecodeTick(
                    output_tokens=produced,
                    kv_cache_bytes=max(0, active - baseline),
                    active_memory_bytes=active,
                ),
                request_id,
            )
            finish = getattr(response, "finish_reason", None) or finish
        _emit(
            fh,
            args.run_id,
            ev.RequestEnd(output_tokens=produced, finish_reason=finish),
            request_id,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
