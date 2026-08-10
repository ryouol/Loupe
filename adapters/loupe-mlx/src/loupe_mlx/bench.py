"""One benchmark run: a single request at an exact prompt length, events to a
file. Driven by loupe-bench once per (context x repeat); one request per
process keeps every measured run cold-state-fair, and the harness's warmup
runs absorb the load costs.

Same `LoupeInstrument` as the live adapter, file sink instead of socket.
"""

from __future__ import annotations

import argparse
import sys

from .adapter import LoupeInstrument
from .socket_writer import FileEventWriter

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
    parser.add_argument(
        "--prompt-base", default=FILLER, help="corpus text prompts are built from"
    )
    return parser


def prompt_of_length(tokenizer, base: str, target_tokens: int) -> str:
    """Deterministic prompt truncated to exactly the requested token count."""
    text = (base + " ") * (target_tokens // max(1, len(base.split())) + 2)
    ids = tokenizer.encode(text)[:target_tokens]
    return tokenizer.decode(ids)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        import mlx.core as mx
    except ImportError:
        print("mlx-lm is not installed; run `make bootstrap-mlx`.", file=sys.stderr)
        return 2

    mx.random.seed(args.seed)
    loupe = LoupeInstrument(run_id=args.run_id, writer=FileEventWriter(args.out))
    try:
        model, tokenizer = loupe.load(args.model)
        prompt = prompt_of_length(tokenizer, args.prompt_base, args.context_tokens)
        for _ in loupe.stream_generate(model, tokenizer, prompt, max_tokens=args.max_tokens):
            pass
    except Exception:
        loupe.close()
        return 1
    loupe.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
