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
    parser.add_argument("--prompt-base", default=FILLER, help="corpus text prompts are built from")
    return parser


def prompt_of_length(tokenizer, base: str, target_tokens: int) -> str:
    """Deterministic prompt truncated to exactly the requested token count."""
    text = (base + " ") * (target_tokens // max(1, len(base.split())) + 2)
    ids = tokenizer.encode(text)[:target_tokens]
    return tokenizer.decode(ids)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.model or not args.out:
        print("--model and --out cannot be empty", file=sys.stderr)
        return 2
    if not 1 <= args.context_tokens <= 131_072:
        print("--context-tokens must be between 1 and 131072", file=sys.stderr)
        return 2
    if not 1 <= args.max_tokens <= 4_096:
        print("--max-tokens must be between 1 and 4096", file=sys.stderr)
        return 2
    if not 0 <= args.seed <= 2**64 - 1:
        print("--seed must be an unsigned 64-bit integer", file=sys.stderr)
        return 2
    if not 1 <= len(args.run_id) <= 128:
        print("--run-id must contain 1 to 128 characters", file=sys.stderr)
        return 2
    if not args.prompt_base or len(args.prompt_base.encode("utf-8")) > 1_048_576:
        print("--prompt-base must contain at most 1 MiB of UTF-8 text", file=sys.stderr)
        return 2
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
