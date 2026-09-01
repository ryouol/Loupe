import sys
import types

import pytest
from loupe_mlx import DEFAULT_SOCKET_PATH, LoupeInstrument, __version__


def test_package_surface() -> None:
    assert __version__ == "0.2.0"
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
