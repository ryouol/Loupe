from loupe_mlx.bench import main


def test_main_rejects_unsafe_limits_before_runtime_import(tmp_path) -> None:
    base = ["--model", "m", "--out", str(tmp_path / "x.ndjson")]
    assert main([*base, "--context-tokens", "0"]) == 2
    assert main([*base, "--context-tokens", "1", "--max-tokens", "0"]) == 2
    assert main([*base, "--context-tokens", "1", "--seed", "-1"]) == 2
    assert main([*base, "--context-tokens", "1", "--prompt-base", ""]) == 2
