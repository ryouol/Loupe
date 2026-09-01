import sys

import pytest
from loupe_mlx.record import PROMPTS, build_parser, main


def test_prompt_corpus_has_varied_lengths() -> None:
    lengths = [len(p) for p in PROMPTS]
    assert len(PROMPTS) >= 4
    assert max(lengths) > 2 * min(lengths), "prefill variety needs length variety"


def test_parser_requires_model_and_out() -> None:
    with pytest.raises(SystemExit):
        build_parser().parse_args([])
    args = build_parser().parse_args(["--model", "m", "--out", "o.ndjson"])
    assert args.duration == 60.0
    assert args.max_tokens == 200


def test_main_without_mlx_fails_cleanly(monkeypatch, tmp_path) -> None:
    # Force the lazy import to fail even on machines that have mlx installed.
    monkeypatch.setitem(sys.modules, "mlx_lm", None)
    monkeypatch.setitem(sys.modules, "mlx.core", None)
    exit_code = main(["--model", "m", "--out", str(tmp_path / "x.ndjson")])
    assert exit_code == 2


def test_main_rejects_unsafe_limits_before_import(tmp_path) -> None:
    output = str(tmp_path / "x.ndjson")
    assert main(["--model", "m", "--out", output, "--duration", "inf"]) == 2
    assert main(["--model", "m", "--out", output, "--max-tokens", "0"]) == 2
    assert main(["--model", "m", "--out", output, "--run-id", "r" * 129]) == 2
