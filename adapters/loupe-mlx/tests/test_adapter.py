"""M1.3 acceptance: real tiny-model runs through the instrumented API.

Skipped wherever mlx-lm isn't installed (CI). The overhead assertion
additionally requires LOUPE_HARDWARE_TESTS=1 because it measures wall time.
"""

import os
import time

import pytest

from loupe_mlx.events import decode_line

mlx_lm = pytest.importorskip("mlx_lm")

from loupe_mlx import LoupeInstrument  # noqa: E402
from test_socket_writer import UnixLineServer  # noqa: E402

MODEL = os.environ.get("LOUPE_FIXTURE_MODEL", "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
PROMPT = "Explain the difference between prefill and decode in one sentence."


@pytest.fixture(scope="module")
def instrumented_run() -> tuple[list, int]:
    server = UnixLineServer()
    loupe = LoupeInstrument(socket_path=server.path, run_id="r-accept")
    model, tokenizer = loupe.load(MODEL)
    produced = 0
    for _ in loupe.stream_generate(model, tokenizer, PROMPT, max_tokens=48):
        produced += 1
    loupe.close()
    server.wait_for(produced + 6)
    return [decode_line(line) for line in server.lines], produced


def test_event_ordering(instrumented_run) -> None:
    events, produced = instrumented_run
    kinds = [envelope.event for envelope in events]

    assert kinds[0] == "session_start"
    assert kinds[1] == "clock_sync"
    assert kinds[2] == "model_load_start"
    assert kinds[3] == "model_load_end"
    assert kinds[4] == "request_start"
    assert kinds[5] == "prefill_end"
    assert kinds[-1] == "request_end"
    assert kinds[6:-1] == ["decode_tick"] * produced

    ticks = [envelope for envelope in events if envelope.event == "decode_tick"]
    assert [tick.payload.output_tokens for tick in ticks] == list(range(1, produced + 1))
    assert all(tick.request_id == "q-1" for tick in ticks)


def test_timestamps_are_monotonic(instrumented_run) -> None:
    events, _ = instrumented_run
    timestamps = [envelope.ts for envelope in events]
    assert timestamps == sorted(timestamps)
    assert all(ts > 0 for ts in timestamps)


def test_ttft_is_prefill_end_minus_request_start(instrumented_run) -> None:
    events, _ = instrumented_run
    request_start = next(e for e in events if e.event == "request_start")
    prefill_end = next(e for e in events if e.event == "prefill_end")
    first_tick = next(e for e in events if e.event == "decode_tick")

    ttft_ns = prefill_end.ts - request_start.ts
    assert ttft_ns > 0
    assert ttft_ns < 60_000_000_000, "TTFT beyond a minute means broken timestamps"
    # The first token can only exist after prefill finished.
    assert first_tick.ts >= prefill_end.ts


def test_memory_counters_are_plausible(instrumented_run) -> None:
    events, _ = instrumented_run
    load_end = next(e for e in events if e.event == "model_load_end")
    assert load_end.payload.ok
    assert load_end.payload.weights_bytes > 50_000_000, "0.5B weights are >50MB"

    ticks = [e for e in events if e.event == "decode_tick"]
    assert all(t.payload.active_memory_bytes >= t.payload.kv_cache_bytes for t in ticks)
    # kv_cache_bytes is an active-memory-growth proxy: the physical KV cache
    # grows monotonically but MLX's allocator frees interleaved buffers, so
    # only the trend is guaranteed — some growth, never negative.
    kv_sizes = [t.payload.kv_cache_bytes for t in ticks]
    assert all(kv >= 0 for kv in kv_sizes)
    assert max(kv_sizes) > 0, "decode should allocate KV-attributable memory"


@pytest.mark.skipif(
    os.environ.get("LOUPE_HARDWARE_TESTS") != "1",
    reason="wall-time measurement; set LOUPE_HARDWARE_TESTS=1",
)
def test_adapter_overhead_under_one_percent() -> None:
    from mlx_lm import load, stream_generate

    model, tokenizer = load(MODEL)
    tokens = 128

    def bare() -> float:
        start = time.perf_counter()
        for _ in stream_generate(model, tokenizer, prompt=PROMPT, max_tokens=tokens):
            pass
        return time.perf_counter() - start

    def instrumented() -> float:
        server = UnixLineServer()
        loupe = LoupeInstrument(socket_path=server.path)
        start = time.perf_counter()
        for _ in loupe.stream_generate(model, tokenizer, PROMPT, max_tokens=tokens):
            pass
        elapsed = time.perf_counter() - start
        loupe.close()
        return elapsed

    bare()  # warmup: caches, lazy graph compilation
    bare_times = []
    instrumented_times = []
    for _ in range(3):
        bare_times.append(bare())
        instrumented_times.append(instrumented())

    bare_median = sorted(bare_times)[1]
    instrumented_median = sorted(instrumented_times)[1]
    overhead = instrumented_median / bare_median - 1.0
    assert overhead < 0.01, (
        f"adapter overhead {overhead * 100:.2f}% exceeds 1% "
        f"(bare {bare_median:.3f}s vs instrumented {instrumented_median:.3f}s)"
    )
