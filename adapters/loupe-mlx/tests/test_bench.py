import io

import pytest
from loupe_mlx.bench import MAX_PROMPT_BYTES, main, prompt_of_length, read_prompt_input


def test_main_rejects_unsafe_limits_before_runtime_import(tmp_path) -> None:
    base = ["--model", "m", "--out", str(tmp_path / "x.ndjson")]
    assert main([*base, "--context-tokens", "0"]) == 2
    assert main([*base, "--context-tokens", "1", "--max-tokens", "0"]) == 2
    assert main([*base, "--context-tokens", "1", "--seed", "-1"]) == 2
    assert (
        main(
            [*base, "--context-tokens", "1", "--prompt-stdin"],
            standard_input=io.BytesIO(),
        )
        == 2
    )


def test_prompt_stdin_is_bounded_utf8_and_never_an_argv_value() -> None:
    sensitive = b"s" * MAX_PROMPT_BYTES
    assert read_prompt_input(io.BytesIO(sensitive)) == sensitive.decode()
    with pytest.raises(ValueError, match="at most"):
        read_prompt_input(io.BytesIO(sensitive + b"x"))
    with pytest.raises(ValueError, match="UTF-8"):
        read_prompt_input(io.BytesIO(b"\xff"))
    with pytest.raises(SystemExit):
        main(
            [
                "--model",
                "m",
                "--out",
                "x",
                "--context-tokens",
                "1",
                "--prompt-base",
                "customer secret",
            ]
        )


def test_prompt_expansion_is_token_bounded_for_large_single_word_corpus() -> None:
    class Tokenizer:
        def encode(self, _text: str) -> list[int]:
            return [1, 2, 3]

        def decode(self, tokens: list[int]) -> str:
            assert len(tokens) == 131_072
            return "bounded"

    corpus = "s" * MAX_PROMPT_BYTES
    assert prompt_of_length(Tokenizer(), corpus, 131_072) == "bounded"
