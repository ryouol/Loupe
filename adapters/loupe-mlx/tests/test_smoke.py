import sys
import threading
import types

import pytest
from loupe_mlx import DEFAULT_SOCKET_PATH, LoupeInstrument, __version__


def test_package_surface() -> None:
    assert __version__ == "0.2.1"
    assert DEFAULT_SOCKET_PATH.endswith(".sock")
    assert LoupeInstrument is not None


class CollectingSink:
    dropped = 0
    connected = True

    def __init__(self) -> None:
        self.events = []

    def emit(self, envelope) -> None:
        self.events.append(envelope)

    def close(self) -> None:
        self.connected = False


class SequenceClock:
    def __init__(self, values: list[int]) -> None:
        self._values = iter(values)

    def __call__(self) -> int:
        return next(self._values)


class OneDropSink(CollectingSink):
    def emit(self, envelope) -> None:
        if envelope.seq == 2:
            self.dropped += 1
        else:
            self.events.append(envelope)


def install_fake_runtime(monkeypatch, stream_generate) -> None:
    mlx = types.ModuleType("mlx")
    mlx.__path__ = []
    core = types.ModuleType("mlx.core")
    core.get_active_memory = lambda: 100
    mlx.core = core
    runtime = types.ModuleType("mlx_lm")
    runtime.stream_generate = stream_generate
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", core)
    monkeypatch.setitem(sys.modules, "mlx_lm", runtime)


def test_generation_failure_does_not_emit_exception_text(monkeypatch) -> None:
    def fail_generation(*_args, **_kwargs):
        raise RuntimeError("secret prompt contents")
        yield  # pragma: no cover - makes this a generator

    install_fake_runtime(monkeypatch, fail_generation)
    sink = CollectingSink()
    loupe = LoupeInstrument(run_id="r-safe", writer=sink)

    with pytest.raises(RuntimeError, match="secret prompt contents"):
        list(loupe.stream_generate(object(), object(), prompt="secret prompt contents"))

    error = next(event.payload for event in sink.events if event.event == "error")
    assert error.message == "Generation failed (RuntimeError)"
    assert "secret" not in error.message


def test_model_load_failure_does_not_emit_exception_text(monkeypatch) -> None:
    def fail_load(*_args, **_kwargs):
        raise RuntimeError("secret cache path and credential")

    install_fake_runtime(monkeypatch, lambda *_args, **_kwargs: iter(()))
    sys.modules["mlx_lm"].load = fail_load
    sink = CollectingSink()
    loupe = LoupeInstrument(run_id="r-safe", writer=sink)

    with pytest.raises(RuntimeError, match="secret cache path"):
        loupe.load("private-model")

    error = next(event.payload for event in sink.events if event.event == "error")
    assert error.message == "Model load failed (RuntimeError)"
    assert "secret" not in error.message


def test_unknown_finish_reason_is_reduced_to_category(monkeypatch) -> None:
    response = types.SimpleNamespace(prompt_tokens=1, finish_reason="generated secret text")

    def generate(*_args, **_kwargs):
        yield response

    install_fake_runtime(monkeypatch, generate)
    sink = CollectingSink()
    loupe = LoupeInstrument(run_id="r-safe", writer=sink)
    list(loupe.stream_generate(object(), object(), prompt="secret"))

    end = next(event.payload for event in sink.events if event.event == "request_end")
    assert end.finish_reason == "other"


def test_adapter_relaunch_does_not_reuse_request_id(monkeypatch) -> None:
    response = types.SimpleNamespace(prompt_tokens=1, prompt_tps=1.0, finish_reason="stop")

    def generate(*_args, **_kwargs):
        yield response

    install_fake_runtime(monkeypatch, generate)
    namespaces = iter(["a" * 32, "b" * 32])
    monkeypatch.setattr(
        "loupe_mlx.adapter.uuid.uuid4",
        lambda: types.SimpleNamespace(hex=next(namespaces)),
    )
    request_ids = []
    for _ in range(2):
        sink = CollectingSink()
        loupe = LoupeInstrument(run_id="r-relaunch", writer=sink)
        list(loupe.stream_generate(object(), object(), prompt="x"))
        loupe.close()
        request_ids.append(
            next(event.request_id for event in sink.events if event.event == "request_start")
        )

    assert request_ids == [f"q-{'a' * 32}-1", f"q-{'b' * 32}-1"]


def test_one_token_early_stop_includes_first_token_interval(monkeypatch) -> None:
    response = types.SimpleNamespace(
        prompt_tokens=8,
        prompt_tps=80.0,
        # mlx-lm 0.31.3 starts this field's timer after token 1. An absurd
        # value proves Loupe does not reuse that partial-window rate.
        generation_tps=1_000_000.0,
        finish_reason="eos",
    )

    def generate(*_args, **kwargs):
        kwargs["prompt_progress_callback"](7, 8)
        yield response

    install_fake_runtime(monkeypatch, generate)
    sink = CollectingSink()
    loupe = LoupeInstrument(
        run_id="r-rate",
        writer=sink,
        clock=SequenceClock([100, 100, 1_000_000_000, 1_100_000_000, 1_140_000_000, 1_150_000_000]),
    )
    assert len(list(loupe.stream_generate(object(), object(), prompt="x"))) == 1
    loupe.close()

    end = next(event.payload for event in sink.events if event.event == "request_end")
    request_start = next(event for event in sink.events if event.event == "request_start")
    first_output = next(event for event in sink.events if event.event == "decode_tick")
    assert end.output_tokens == 1
    assert end.finish_reason == "eos"
    assert first_output.ts - request_start.ts == 140_000_000
    assert end.decode_duration_ns == 40_000_000
    assert end.output_tokens / (end.decode_duration_ns / 1_000_000_000) == 25.0
    summary = next(event.payload for event in sink.events if event.event == "transport_summary")
    assert summary.producer_dropped_events == 0
    sequences = [event.seq for event in sink.events]
    assert sequences == list(range(1, len(sequences) + 1))


def test_consumer_early_stop_closes_the_same_decode_window(monkeypatch) -> None:
    response = types.SimpleNamespace(
        prompt_tokens=8,
        prompt_tps=80.0,
        generation_tps=999_999.0,
        finish_reason=None,
    )

    def generate(*_args, **kwargs):
        kwargs["prompt_progress_callback"](7, 8)
        yield response
        yield response

    install_fake_runtime(monkeypatch, generate)
    sink = CollectingSink()
    loupe = LoupeInstrument(
        run_id="r-cancel",
        writer=sink,
        clock=SequenceClock(
            [100, 100, 1_000_000_000, 1_100_000_000, 1_140_000_000, 1_170_000_000, 1_180_000_000]
        ),
    )
    generated = loupe.stream_generate(object(), object(), prompt="x")
    next(generated)
    generated.close()
    loupe.close()

    end = next(event.payload for event in sink.events if event.event == "request_end")
    assert end.output_tokens == 1
    assert end.finish_reason == "cancelled"
    assert end.decode_duration_ns == 40_000_000


def test_terminal_summary_reports_adapter_queue_loss() -> None:
    sink = OneDropSink()
    loupe = LoupeInstrument(run_id="r-drop", writer=sink)
    loupe.close()

    assert [event.seq for event in sink.events] == [1, 3]
    summary = sink.events[-1].payload
    assert summary.producer_dropped_events == 1
    assert summary.attempted_events == 2


def test_reordered_clock_reads_are_clamped_to_monotonic_emission() -> None:
    sink = CollectingSink()
    loupe = LoupeInstrument(run_id="r-clock", writer=sink, clock=SequenceClock([300, 200, 100]))
    loupe.close()

    assert [event.event for event in sink.events] == [
        "session_start",
        "clock_sync",
        "transport_summary",
    ]
    assert [event.ts for event in sink.events] == [300, 300, 300]


def test_concurrent_generation_is_rejected_and_close_waits_for_request_end(monkeypatch) -> None:
    entered_runtime = threading.Event()
    release_runtime = threading.Event()
    response = types.SimpleNamespace(prompt_tokens=1, prompt_tps=1.0, finish_reason="stop")

    def generate(*_args, **_kwargs):
        entered_runtime.set()
        assert release_runtime.wait(timeout=2)
        yield response

    install_fake_runtime(monkeypatch, generate)
    sink = CollectingSink()
    loupe = LoupeInstrument(run_id="r-concurrent", writer=sink)
    failures: list[BaseException] = []

    def consume() -> None:
        try:
            list(loupe.stream_generate(object(), object(), prompt="first"))
        except BaseException as exc:  # pragma: no cover - asserted below
            failures.append(exc)

    worker = threading.Thread(target=consume)
    worker.start()
    assert entered_runtime.wait(timeout=2)

    with pytest.raises(RuntimeError, match="one active"):
        list(loupe.stream_generate(object(), object(), prompt="second"))

    closers = [threading.Thread(target=loupe.close) for _ in range(4)]
    for closer in closers:
        closer.start()
    for closer in closers:
        closer.join(timeout=2)
    assert not any(closer.is_alive() for closer in closers)
    assert not any(event.event == "transport_summary" for event in sink.events)

    release_runtime.set()
    worker.join(timeout=2)
    assert not worker.is_alive()
    assert failures == []

    kinds = [event.event for event in sink.events]
    assert kinds[-2:] == ["request_end", "transport_summary"]
    assert kinds.count("transport_summary") == 1
    assert [event.seq for event in sink.events] == list(range(1, len(sink.events) + 1))
    assert [event.ts for event in sink.events] == sorted(event.ts for event in sink.events)
    with pytest.raises(RuntimeError, match="closed"):
        list(loupe.stream_generate(object(), object(), prompt="after-close"))


def test_missing_runtime_boundary_does_not_invent_decode_time(monkeypatch):
    response = types.SimpleNamespace(prompt_tokens=8, prompt_tps=80.0, finish_reason="stop")

    def generate(*_args, **_kwargs):
        yield response

    install_fake_runtime(monkeypatch, generate)
    sink = CollectingSink()
    loupe = LoupeInstrument(writer=sink, clock=SequenceClock([1, 2, 100, 200, 300]))
    list(loupe.stream_generate(object(), object(), "x"))
    loupe.close()
    end = next(e.payload for e in sink.events if e.event == "request_end")
    assert end.decode_duration_ns is None


def test_prefill_boundary_observed_after_host_setup_and_callback_forwarded(monkeypatch):
    response = types.SimpleNamespace(prompt_tokens=8, prompt_tps=800.0, finish_reason="length")
    forwarded = []

    def generate(*_args, **kwargs):
        kwargs["prompt_progress_callback"](0, 8)
        kwargs["prompt_progress_callback"](7, 8)
        kwargs["prompt_progress_callback"](8, 8)
        yield response

    install_fake_runtime(monkeypatch, generate)
    sink = CollectingSink()
    loupe = LoupeInstrument(writer=sink, clock=SequenceClock([1, 2, 100, 900, 1000, 1100]))
    list(
        loupe.stream_generate(
            object(), object(), "x", prompt_progress_callback=lambda p, t: forwarded.append((p, t))
        )
    )
    loupe.close()
    assert forwarded == [(0, 8), (7, 8), (8, 8)]
    boundary = next(e for e in sink.events if e.event == "prefill_end")
    assert boundary.ts == 900
    assert (
        next(e.payload for e in sink.events if e.event == "request_end").decode_duration_ns == 100
    )
