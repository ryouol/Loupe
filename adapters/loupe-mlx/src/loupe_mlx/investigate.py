"""Repeatable, resident-model MLX investigation with independent client timing.

Unlike bench (one process/request), warmups here warm the measured model instance.
Only synthetic prompts are generated. No prompt or output text is exported.
"""

from __future__ import annotations

import argparse
import cProfile
import csv
import hashlib
import importlib.metadata
import json
import platform
import pstats
import subprocess
from pathlib import Path

from .adapter import LoupeInstrument
from .bench import FILLER
from .socket_writer import FileEventWriter
from .timebase import now_ns


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def summarize_events(events: list[dict]) -> list[dict]:
    """Keep cancellations/errors visible without treating them as completed runs."""
    requests: dict[str, dict] = {}
    for event in events:
        rid = event.get("requestId")
        if not rid:
            continue
        r = requests.setdefault(rid, {"request_id": rid, "status": "incomplete"})
        kind = event["event"]
        if kind == "request_start":
            r["start_ns"] = event["ts"]
        elif kind == "decode_tick" and event["payload"]["outputTokens"] > 0:
            r.setdefault("first_token_ns", event["ts"])
        elif kind == "request_end":
            r["status"] = event["payload"]["finishReason"]
            r["output_tokens"] = event["payload"]["outputTokens"]
            r["decode_duration_ns"] = event["payload"].get("decodeDurationNs")
            r["end_ns"] = event["ts"]
    for r in requests.values():
        r["completed"] = r["status"] in {"stop", "length", "eos"}
        start, first = r.get("start_ns"), r.get("first_token_ns")
        r["ttft_ms"] = (first - start) / 1e6 if start is not None and first is not None else None
    return list(requests.values())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True, help="pinned local model directory")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--out", type=Path, required=True, help="new evidence directory")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--contexts", type=int, nargs="+", default=[128, 2048])
    parser.add_argument("--outputs", type=int, nargs="+", default=[32, 128])
    parser.add_argument("--steps", type=int, nargs="+", default=[64, 512])
    args = parser.parse_args(argv)
    if not args.model.is_dir() or not 1 <= args.repeats <= 20:
        parser.error("model must exist; repeats must be 1..20")
    if not args.revision or len(args.revision) > 128:
        parser.error("a bounded model revision is required")
    if any(not 1 <= n <= 8192 for n in args.contexts + args.steps):
        parser.error("contexts and prefill steps must be 1..8192")
    if any(not 4 <= n <= 512 for n in args.outputs):
        parser.error("outputs must be 4..512")
    if len(args.contexts) * len(args.outputs) * len(args.steps) * args.repeats > 200:
        parser.error("at most 200 measured requests")

    import mlx.core as mx
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    args.out.mkdir(parents=True, exist_ok=False)
    model_files = {
        p.name: digest(p)
        for p in sorted(args.model.iterdir())
        if p.is_file() and p.suffix in {".json", ".safetensors", ".model"}
    }
    root = Path(__file__).resolve().parents[4]
    git = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True
    ).stdout.strip()
    manifest = {
        "schema_version": 1,
        "source_commit": git,
        "source_files_sha256": {p.name: digest(p) for p in Path(__file__).parent.glob("*.py")},
        "model_revision": args.revision,
        "model_files_sha256": model_files,
        "device": mx.device_info(),
        "os": platform.mac_ver()[0],
        "python": platform.python_version(),
        "versions": {k: importlib.metadata.version(k) for k in ["mlx", "mlx-lm", "transformers"]},
        "dependency_lock_sha256": digest(root / "adapters/loupe-mlx/uv.lock"),
        "contexts": args.contexts,
        "outputs": args.outputs,
        "prefill_steps": args.steps,
        "repeats": args.repeats,
        "sampling": "greedy; seed 42 reset per request; fresh KV cache per request",
        "prompt": "synthetic filler token IDs, exactly truncated; no chat template",
        "clock": "mach_continuous_time nanoseconds; client and adapter in same process",
        "ttft_boundary": "first generated token response, possibly empty decoded text; text TTFT separate",
        "measurement": "unprofiled; resident model; one warmup per condition; alternating step order",
    }
    instrument = LoupeInstrument(
        run_id="r-investigation", writer=FileEventWriter(str(args.out / "session.ndjson"))
    )
    profiler = cProfile.Profile()
    rows = []
    load_start = now_ns()
    try:
        model, tokenizer = instrument.load(str(args.model))
        manifest["model_load_ms"] = (now_ns() - load_start) / 1e6
        base = tokenizer.encode(FILLER)
        if not base:
            raise ValueError("empty prompt tokenization")

        def run(
            context: int, output: int, step: int, phase: str, repeat: int, traced: bool = True
        ) -> None:
            ids = (base * ((context + len(base) - 1) // len(base)))[:context]
            mx.random.seed(42)
            mx.reset_peak_memory()
            generate = instrument.stream_generate if traced else stream_generate
            start = now_ns()
            first = first_text = last = None
            tokens = []
            runtime_prompt_tokens = None
            iterator = generate(
                model,
                tokenizer,
                prompt=ids,
                max_tokens=output,
                sampler=make_sampler(temp=0),
                prefill_step_size=step,
            )
            try:
                for response in iterator:
                    last = now_ns()
                    if first is None:
                        first = last
                    if response.text and first_text is None:
                        first_text = last
                    tokens.append(int(response.token))
                    runtime_prompt_tokens = int(response.prompt_tokens)
                    if phase == "cancelled" and len(tokens) == 3:
                        break
            finally:
                iterator.close()
            end = now_ns()
            rows.append(
                {
                    "phase": phase,
                    "repeat": repeat,
                    "context_tokens": context,
                    "output_limit": output,
                    "prefill_step": step,
                    "instrumented": traced,
                    "client_start_ns": start,
                    "client_first_ns": first,
                    "client_last_ns": last,
                    "client_end_ns": end,
                    "client_ttft_ms": (first - start) / 1e6 if first is not None else None,
                    "client_text_ttft_ms": (first_text - start) / 1e6
                    if first_text is not None
                    else None,
                    "client_total_ms": (end - start) / 1e6,
                    "observed_tokens": len(tokens),
                    "runtime_prompt_tokens": runtime_prompt_tokens,
                    "output_token_ids_sha256": hashlib.sha256(
                        json.dumps(tokens).encode()
                    ).hexdigest(),
                    "peak_allocator_bytes": mx.get_peak_memory(),
                }
            )

        for context in args.contexts:
            for output in args.outputs:
                for step in args.steps:
                    run(context, output, step, "warmup", -1)
                for repeat in range(args.repeats):
                    steps = args.steps if repeat % 2 == 0 else list(reversed(args.steps))
                    for step in steps:
                        run(context, output, step, "measured", repeat)
        # Paired overhead controls use the same live model and workload.
        for repeat in range(args.repeats):
            for traced in [False, True] if repeat % 2 == 0 else [True, False]:
                run(args.contexts[0], args.outputs[-1], args.steps[-1], "overhead", repeat, traced)
        run(args.contexts[0], args.outputs[-1], args.steps[-1], "cancelled", 0)
        # Keep profiler overhead out of headline measurements.
        profiler.enable()
        for step in args.steps:
            run(args.contexts[-1], args.outputs[-1], step, "profiled", 0)
        profiler.disable()
    finally:
        instrument.close()
        (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (args.out / "client.json").write_text(json.dumps(rows, indent=2) + "\n")
    events = [json.loads(line) for line in (args.out / "session.ndjson").read_text().splitlines()]
    metrics = summarize_events(events)
    traced_rows = [r for r in rows if r["instrumented"]]
    if len(metrics) != len(traced_rows):
        raise ValueError("client/event request counts disagree")
    for row, metric in zip(traced_rows, metrics, strict=True):
        row["request_id"] = metric["request_id"]
        row["event_ttft_ms"] = metric["ttft_ms"]
        row["finish_reason"] = metric["status"]
        row["timing_verified"] = (
            row["client_start_ns"]
            <= metric["start_ns"]
            <= metric["first_token_ns"]
            <= row["client_first_ns"]
            and metric["end_ns"] <= row["client_end_ns"]
            and row["observed_tokens"] == metric["output_tokens"]
        )
        if not row["timing_verified"] or row["runtime_prompt_tokens"] != row["context_tokens"]:
            raise ValueError("timing or prompt-length validation failed")
    if not any(r["status"] == "cancelled" and not r["completed"] for r in metrics):
        raise ValueError("cancellation was not recorded")
    (args.out / "client.json").write_text(json.dumps(rows, indent=2) + "\n")
    (args.out / "requests.json").write_text(json.dumps(metrics, indent=2) + "\n")
    with (args.out / "client.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=sorted({k for r in rows for k in r}))
        writer.writeheader()
        writer.writerows(rows)
    profiler.dump_stats(str(args.out / "host.pstats"))
    with (args.out / "host-profile.txt").open("w") as f:
        pstats.Stats(profiler, stream=f).strip_dirs().sort_stats("cumulative").print_stats(40)
    print(f"Verified {len(metrics)} traced requests, including cancellation; results: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
