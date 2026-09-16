import json

import pytest
from loupe_mlx import events as ev
from loupe_mlx.import_serving import import_capture, main
from loupe_mlx.investigate import summarize_events


def test_incomplete_and_cancelled_requests_stay_visible_but_not_completed():
    def envelope(ts, payload, rid="q"):
        return json.loads(ev.encode_line(ev.Envelope(ts, "r", payload, request_id=rid)))

    events = [
        envelope(100, ev.RequestStart()),
        envelope(200, ev.DecodeTick(output_tokens=1, active_memory_bytes=100)),
    ]
    assert summarize_events(events)[0]["status"] == "incomplete"
    events.append(envelope(300, ev.RequestEnd(output_tokens=1, finish_reason="cancelled")))
    result = summarize_events(events)[0]
    assert result["completed"] is False
    assert result["status"] == "cancelled"
    assert result["ttft_ms"] == 0.0001


def capture():
    return {
        "schema": "loupe-serving-capture/v1",
        "duration_ms": 1000,
        "provenance": {
            "runtime": "vllm",
            "runtime_version": "test-version",
            "model_revision": "fixture",
            "hardware": "synthetic",
            "workload_sha256": "ab" * 32,
        },
        "requests": [
            {
                "id": "q",
                "status": "ok",
                "start_ms": 0,
                "first_token_ms": 100,
                "end_ms": 500,
                "output_tokens": 20,
            },
            {
                "id": "timeout",
                "status": "timeout",
                "start_ms": 0,
                "first_token_ms": None,
                "end_ms": 1000,
                "output_tokens": 0,
            },
        ],
        "server_aggregate_metrics": {"kv_cache_usage_ratio": 0.5},
    }


def test_serving_import_keeps_remote_aggregates_separate_and_counts_failures():
    report = import_capture(capture())
    assert report["successful_output_tokens_per_second"] == 20
    assert report["outcomes"] == {"ok": 1, "timeout": 1}
    assert report["ttft_p99_ms"] is None
    assert report["requests"][0]["prefill_ms"] is None
    assert report["requests"][0]["decode_tokens_per_second"] is None
    assert report["server_aggregate_metrics"]["kv_cache_usage_ratio"] == 0.5


@pytest.mark.parametrize(
    "key,value",
    [
        ("first_token_ms", 600),
        ("start_ms", -1),
        ("end_ms", float("nan")),
        ("end_ms", 1001),
        ("output_tokens", True),
        ("output_tokens", 2.5),
    ],
)
def test_serving_import_rejects_invalid_boundaries(key, value):
    data = capture()
    data["requests"][0][key] = value
    with pytest.raises(ValueError):
        import_capture(data)


def test_serving_import_rejects_duplicate_ids_and_missing_provenance():
    data = capture()
    data["requests"][1]["id"] = "q"
    with pytest.raises(ValueError, match="unique"):
        import_capture(data)
    data = capture()
    del data["provenance"]["hardware"]
    with pytest.raises(ValueError, match="provenance"):
        import_capture(data)


def test_serving_cli_hashes_source_escapes_csv_and_refuses_overwrite(tmp_path):
    data = capture()
    data["requests"][0]["id"] = "=1+1"
    source = tmp_path / "capture.json"
    source.write_text(json.dumps(data))
    out = tmp_path / "imported"
    assert main(["--input", str(source), "--out", str(out)]) == 0
    assert len(json.loads((out / "report.json").read_text())["source_sha256"]) == 64
    assert "'=1+1" in (out / "requests.csv").read_text()
    with pytest.raises(FileExistsError):
        main(["--input", str(source), "--out", str(out)])
