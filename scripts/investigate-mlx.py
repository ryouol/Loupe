"""Reproducible local experiment; raw client receipts are independent of Loupe clocks."""

import argparse
import hashlib
import importlib.metadata
import json
import os
import subprocess
import sys
import threading
import time
from collections import Counter
from pathlib import Path

import mlx.core as mx
import mlx_lm
from loupe_mlx import LoupeInstrument
from loupe_mlx.bench import FILLER, prompt_of_length
from loupe_mlx.bpe_cache import cache_bpe_vocabulary
from loupe_mlx.socket_writer import FileEventWriter
from mlx_lm.sample_utils import make_sampler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--recorder", required=True)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--experiment", choices=["tokens", "bpe"], default="tokens")
    parser.add_argument("--collection", choices=["on", "off"], default="on")
    parser.add_argument("--slowest-only", action="store_true")
    args = parser.parse_args()
    if args.repeats < 1 or args.repeats > 20:
        parser.error("repeats must be between 1 and 20")
    if Path(args.model).name != "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3":
        parser.error(
            "Use the pinned Qwen2.5-0.5B-Instruct-4bit snapshot documented in the case study"
        )
    out = Path(args.out)
    if (out / "client.json").exists():
        parser.error("Choose a new output directory; experiment receipts are never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    base = out / "capture"
    recorder = None
    if args.collection == "on":
        recorder = subprocess.Popen(
            [
                args.recorder,
                "--out",
                str(base) + ".system.ndjson",
                "--pid",
                str(os.getpid()),
                "--duration",
                "300",
                "--hz",
                "5",
            ]
        )
    instrument = (
        LoupeInstrument(run_id="mlx-investigation", writer=FileEventWriter(str(base) + ".ndjson"))
        if args.collection == "on"
        else mlx_lm
    )
    stacks = Counter()
    done = threading.Event()
    main_id = threading.get_ident()

    def sample():
        while not done.wait(0.01):
            frame = sys._current_frames().get(main_id)
            stack = []
            while frame:
                stack.append(
                    f"{Path(frame.f_code.co_filename).name}:{frame.f_code.co_name}:{frame.f_lineno}"
                )
                frame = frame.f_back
            stacks[";".join(reversed(stack))] += 1

    sampler = threading.Thread(target=sample, daemon=True)
    if args.collection == "on":
        sampler.start()
    rows = []
    load_start = time.perf_counter_ns()
    model, tokenizer = instrument.load(args.model)
    mx.synchronize()
    load_ns = time.perf_counter_ns() - load_start
    setup_start = time.perf_counter_ns()
    cached_tokenizer = cache_bpe_vocabulary(tokenizer)
    setup_ns = time.perf_counter_ns() - setup_start
    prompts = {n: prompt_of_length(tokenizer, FILLER, n) for n in (128, 8192)}
    tokens = {
        n: tokenizer.encode(
            p,
            add_special_tokens=tokenizer.bos_token is None or not p.startswith(tokenizer.bos_token),
        )
        for n, p in prompts.items()
    }

    def run(context, limit, mode, repeat, cancel=False):
        mx.random.seed(42)
        start = time.perf_counter_ns()
        responses = []
        progress = []
        text = []

        def client_progress(processed, total):
            progress.append(
                {
                    "processed": processed,
                    "total": total,
                    "elapsed_ns": time.perf_counter_ns() - start,
                }
            )

        stream = instrument.stream_generate(
            model,
            cached_tokenizer if mode == "cached_bpe" else tokenizer,
            prompt=tokens[context] if mode == "cached_tokens" else prompts[context],
            max_tokens=limit,
            sampler=make_sampler(temp=0),
            prompt_progress_callback=client_progress,
        )
        for response in stream:
            receipt = time.perf_counter_ns()
            responses.append(
                {
                    "elapsed_ns": receipt - start,
                    "generation_tokens": response.generation_tokens,
                    "prompt_tokens": response.prompt_tokens,
                    "prompt_tps": response.prompt_tps,
                    "finish_reason": response.finish_reason,
                    "token": response.token,
                }
            )
            text.append(response.text)
            if cancel and len(responses) == 8:
                stream.close()
                break
        elapsed = time.perf_counter_ns() - start
        pressure = subprocess.run(
            ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True
        )
        row = {
            "context": context,
            "limit": limit,
            "mode": mode,
            "repeat": repeat,
            "cancelled": cancel,
            "elapsed_ns": elapsed,
            "responses": responses,
            "progress": progress,
            "output_sha256": hashlib.sha256("".join(text).encode()).hexdigest(),
            "active_memory_bytes": mx.get_active_memory(),
            "peak_memory_bytes": mx.get_peak_memory(),
            "memory_pressure_level": pressure.stdout.strip() if pressure.returncode == 0 else None,
        }
        rows.append(row)
        (out / "client.json").write_text(
            json.dumps(
                {"cold_process_load_ns": load_ns, "cached_bpe_setup_ns": setup_ns, "runs": rows},
                indent=2,
            )
            + "\n"
        )
        print(mode, context, limit, repeat, round(elapsed / 1e6, 2), flush=True)

    try:
        run(128, 32, "warmup", 0)
        candidate = "cached_tokens" if args.experiment == "tokens" else "cached_bpe"
        for repeat in range(args.repeats):
            for context in (8192,) if args.slowest_only else (128, 8192):
                for limit in (128,) if args.slowest_only else (32, 128):
                    # Alternate order to reduce systematic warmup/thermal bias.
                    for mode in ("string", candidate) if repeat % 2 == 0 else (candidate, "string"):
                        run(context, limit, mode, repeat)
        run(8192, 128, "string", args.repeats, cancel=True)
    finally:
        if args.collection == "on":
            instrument.close()
        done.set()
        if args.collection == "on":
            sampler.join()
        # Recorder is bounded independently; retain only completed NDJSON rows.
        if recorder is not None:
            recorder.terminate()
            recorder.wait()
        (out / "python-samples.folded").write_text(
            "".join(f"{stack} {count}\n" for stack, count in stacks.items())
        )
        files = {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in Path(args.model).iterdir()
            if p.is_file()
        }
        manifest = {
            "collection": args.collection,
            "baseline_commit": "cc5d120b7ada850e4ce2f26850a6c855dfc76f66",
            "model": "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            "revision": Path(args.model).name,
            "model_files_sha256": files,
            "versions": {
                p: importlib.metadata.version(p)
                for p in ("mlx", "mlx-lm", "transformers", "loupe-mlx")
            },
            "python": sys.version,
            "machine": {
                "chip": subprocess.check_output(
                    ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
                ).strip(),
                "memory_bytes": int(
                    subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)
                ),
            },
            "source_sha256": {
                str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (
                    Path(__file__),
                    Path("adapters/loupe-mlx/src/loupe_mlx/adapter.py"),
                    Path("adapters/loupe-mlx/src/loupe_mlx/bpe_cache.py"),
                )
            },
            "sampler": "greedy temperature=0",
            "seed": 42,
            "prompt_source": "loupe_mlx.bench.FILLER",
            "prompt_token_counts": {n: len(v) for n, v in tokens.items()},
            "python_sampling": {
                "interval_ms": 10,
                "samples": sum(stacks.values()),
                "scope": "Python main-thread stacks; not GPU kernel timing; GIL scheduling bias possible",
            },
            "telemetry_acquisition": (
                "Recorder terminated after workload; acquisition loss unknown. No GPU attribution."
                if args.collection == "on"
                else "Disabled; no telemetry collected"
            ),
        }
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
