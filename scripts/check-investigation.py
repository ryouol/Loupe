"""Audit real client receipts against Loupe's actual Swift replay/export path."""

import argparse
import csv
import json
import statistics
import subprocess
import tempfile
from pathlib import Path


def audit(directory, exporter):
    events = [json.loads(line) for line in (directory / "capture.ndjson").read_text().splitlines()]
    client = json.loads((directory / "client.json").read_text())
    groups = []
    for event in events:
        if event["event"] == "request_start":
            groups.append([])
        if event.get("requestId"):
            groups[-1].append(event)
    assert len(groups) == len(client["runs"])
    ttft_errors, boundary_errors, decode_errors = [], [], []
    for row, group in zip(client["runs"], groups, strict=True):
        first = next(e for e in group if e["event"] == "decode_tick")
        prefill = next(e for e in group if e["event"] == "prefill_end")
        end = group[-1]
        assert end["event"] == "request_end"
        assert end["payload"]["outputTokens"] == row["responses"][-1]["generation_tokens"]
        assert (end["payload"]["finishReason"] == "cancelled") == row["cancelled"]
        ttft_errors.append(abs(row["responses"][0]["elapsed_ns"] - (first["ts"] - group[0]["ts"])))
        if row.get("progress"):
            boundary = next(
                p["elapsed_ns"] for p in row["progress"] if p["processed"] == p["total"] - 1
            )
            boundary_errors.append(abs(boundary - (prefill["ts"] - group[0]["ts"])))
            decode_errors.append(
                abs(
                    row["responses"][-1]["elapsed_ns"]
                    - boundary
                    - end["payload"]["decodeDurationNs"]
                )
            )
    assert max(ttft_errors) < 2_000_000
    if boundary_errors:
        assert max(boundary_errors) < 2_000_000
        assert max(decode_errors) < 2_000_000
    subprocess.run([exporter, str(directory / "capture"), str(directory / "evidence")], check=True)
    report = json.loads((directory / "evidence.json").read_text())
    assert report["droppedEventLines"] == report["droppedSampleLines"] == 0
    assert len(report["requests"]) == len(client["runs"])
    assert report["requestOutcomes"][-1]["finishReason"] == "cancelled"
    csv_rows = list(csv.DictReader((directory / "evidence.csv").open()))
    assert any(
        r["record_type"] == "request_outcome" and r["value"] == "cancelled" for r in csv_rows
    )
    last_start = max(i for i, e in enumerate(events) if e["event"] == "request_start")
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary) / "interrupted"
        base.with_suffix(".ndjson").write_text(
            "".join(json.dumps(e) + "\n" for e in events[: last_start + 4])
        )
        Path(str(base) + ".system.ndjson").write_bytes(
            (directory / "capture.system.ndjson").read_bytes()
        )
        subprocess.run([exporter, str(base), str(base) + "-export"], check=True)
        truncated = json.loads(Path(str(base) + "-export.json").read_text())
        assert len(truncated["requests"]) == len(report["requests"]) - 1
        assert truncated["requestOutcomes"][-1]["finishReason"] == "incomplete"
        assert truncated.get("eventAcquisitionLosses") is None
        # Removing a required source must fail, not create an all-zero report.
        Path(str(base) + ".system.ndjson").unlink()
        failed = subprocess.run([exporter, str(base), str(base) + "-missing"], capture_output=True)
        assert failed.returncode != 0
        assert not Path(str(base) + "-missing.json").exists()
    summaries = []
    for context in (128, 8192):
        for limit in (32, 128):
            rows = [
                r
                for r in client["runs"]
                if r["context"] == context
                and r["limit"] == limit
                and not r["cancelled"]
                and r["mode"] != "warmup"
            ]
            modes = sorted({r["mode"] for r in rows})
            left = [r for r in rows if r["mode"] == modes[0]]
            right = [r for r in rows if r["mode"] == modes[1]]
            assert len(left) == len(right) >= 5
            for a, b in zip(left, right, strict=True):
                assert a["repeat"] == b["repeat"]
                assert a["output_sha256"] == b["output_sha256"]
                assert [x["token"] for x in a["responses"]] == [x["token"] for x in b["responses"]]
            result = {
                "context": context,
                "output_limit": limit,
                "repeats": len(left),
                "tokens_and_text_identical": True,
            }
            for mode in modes:
                selected = [r for r in rows if r["mode"] == mode]
                result[mode] = {
                    "ttft_median_ms": statistics.median(
                        r["responses"][0]["elapsed_ns"] / 1e6 for r in selected
                    ),
                    "elapsed_median_ms": statistics.median(r["elapsed_ns"] / 1e6 for r in selected),
                    "elapsed_ms": [r["elapsed_ns"] / 1e6 for r in selected],
                    "host_setup_median_ms": statistics.median(
                        r["progress"][0]["elapsed_ns"] / 1e6 for r in selected
                    )
                    if selected[0].get("progress")
                    else None,
                }
            summaries.append(result)
    summary = {
        "conditions": summaries,
        "maximum_ttft_boundary_error_ms": max(ttft_errors) / 1e6,
        "maximum_prefill_boundary_error_ms": max(boundary_errors) / 1e6
        if boundary_errors
        else None,
        "maximum_decode_duration_error_ms": max(decode_errors) / 1e6 if decode_errors else None,
        "cold_process_load_ms": client["cold_process_load_ns"] / 1e6,
        "cache_setup_ms": client.get("cached_bpe_setup_ns", 0) / 1e6,
        "cancelled_verified": True,
        "truncated_request_omitted_from_metrics": True,
        "truncated_outcome_preserved": True,
        "missing_telemetry_rejected": True,
        "acquisition_loss": "unknown; no recorder terminal acquisition summary",
        "thermal_states": report["thermalStates"],
    }
    (directory / "audit.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--exporter", default=".build/debug/loupe-export")
    args = parser.parse_args()
    audit(args.directory, args.exporter)
