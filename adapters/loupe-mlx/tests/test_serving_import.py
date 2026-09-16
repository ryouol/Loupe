import hashlib
import json

import pytest
from loupe_mlx.serving_import import csv_report, import_report, main


@pytest.fixture
def sources(tmp_path):
    client = tmp_path / "client.json"
    metrics = tmp_path / "metrics.prom"
    provenance = tmp_path / "provenance.json"
    client.write_text(
        json.dumps(
            {
                "input_lens": [12, 14, 10],
                "output_lens": [3, 0, 1],
                "ttfts": [0.2, 0, 0],
                "itls": [[0.03], [], []],
                "errors": ["", "sensitive failure detail", ""],
                "completed": 2,
                "duration": 1.2,
                "generated_texts": ["private", "", "other"],
            }
        )
    )
    metrics.write_text(
        "# TYPE vllm:request_prefill_time_seconds histogram\n"
        'vllm:request_prefill_time_seconds_bucket{le="+Inf"} 50\n'
        "vllm:gpu_cache_usage_perc 0.75\n"
        "vllm:optional_value NaN\n"
    )
    provenance.write_text(
        json.dumps(
            {
                "format": "vllm-bench-serve-detailed-v0.12",
                "run_id": "synthetic-test-only",
                "client_host": "load-client",
                "server_host": "remote-gpu",
                "runtime_version": "0.12.0",
                "model_revision": "test-revision",
                "metrics_captured_at": "2026-09-16T16:00:00Z",
            }
        )
    )
    return client, metrics, provenance


def test_scopes_missingness_privacy_and_source_identity(sources):
    report = import_report(*sources)
    request, failed, unavailable = report["requests"]
    assert request["client_ttft_seconds"] == 0.2
    assert request["stream_chunk_gaps_seconds"] == [0.03]
    assert request["server_prefill_seconds"] is None
    assert request["client_e2e_seconds"] is None
    assert failed["status"] == "error"
    assert failed["client_ttft_seconds"] is None
    assert unavailable["client_ttft_seconds"] is None
    assert all(s["host"] == "remote-gpu" for s in report["runtime_aggregate"])
    assert report["runtime_aggregate"][-1]["value"] is None
    assert (
        report["sources"]["client"]["sha256"] == hashlib.sha256(sources[0].read_bytes()).hexdigest()
    )
    encoded = json.dumps(report, allow_nan=False)
    assert "private" not in encoded and "sensitive failure detail" not in encoded
    assert "local_system" not in encoded
    assert "remote_runtime_aggregate_snapshot" in csv_report(report)


@pytest.mark.parametrize(
    "mutation",
    [
        {"ttfts": [0.2]},
        {"ttfts": [float("nan"), 0, 0]},
        {"output_lens": [-1, 0, 1]},
        {"itls": [[-1], [], []]},
        {"completed": 3},
        {"input_lens": [True, 14, 10]},
        {"errors": [None, "error", ""]},
    ],
)
def test_invalid_or_ambiguous_client_rows_fail(sources, mutation):
    client = json.loads(sources[0].read_text())
    client.update(mutation)
    sources[0].write_text(json.dumps(client))
    with pytest.raises(ValueError):
        import_report(*sources)


def test_provenance_required_and_csv_formula_escaped(sources):
    provenance = json.loads(sources[2].read_text())
    provenance["server_host"] = "=SUM(1,2)"
    sources[2].write_text(json.dumps(provenance))
    assert "'=SUM(1,2)" in csv_report(import_report(*sources))
    del provenance["model_revision"]
    sources[2].write_text(json.dumps(provenance))
    with pytest.raises(ValueError, match="Provenance"):
        import_report(*sources)


def test_cli_writes_both_formats_and_refuses_overwrite(sources, tmp_path):
    args = [
        "--client",
        str(sources[0]),
        "--metrics",
        str(sources[1]),
        "--provenance",
        str(sources[2]),
        "--out",
        str(tmp_path / "imported"),
    ]
    assert main(args) == 0
    assert (tmp_path / "imported/serving.csv").is_file()
    assert json.loads((tmp_path / "imported/serving.json").read_text())["schema_version"] == 1
    with pytest.raises(SystemExit) as error:
        main(args)
    assert error.value.code == 2


def test_bad_metrics_and_oversized_sources_rejected(sources, monkeypatch):
    sources[1].write_text("this is not a metric\n")
    with pytest.raises(ValueError, match="Prometheus"):
        import_report(*sources)
    monkeypatch.setattr("loupe_mlx.serving_import.MAX_BYTES", 1)
    with pytest.raises(ValueError, match="64 MiB"):
        import_report(*sources)
