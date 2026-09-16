"""Offline vLLM detailed-result import, kept separate from local Mac telemetry."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import re
from pathlib import Path

MAX_BYTES = 64 * 1024 * 1024
MAX_REQUESTS = 100_000
SERIES = re.compile(
    r'([a-zA-Z_:][a-zA-Z0-9_:]*(?:\{(?:[^"{}]|"(?:[^"\\]|\\.)*")*\})?)\s+(\S+)(?:\s+(-?\d+))?'
)


def read_source(path: Path):
    with path.open("rb") as source:
        data = source.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("Source exceeds 64 MiB")
    return data.decode("utf-8"), {"filename": path.name, "sha256": hashlib.sha256(data).hexdigest()}


def number(value, name, *, integer=False):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError(f"{name} must be a finite nonnegative number")
    if integer and type(value) is not int:
        raise ValueError(f"{name} must be an integer")
    return value


def import_report(client_path: Path, metrics_path: Path, provenance_path: Path):
    client_text, client_source = read_source(client_path)
    metrics_text, metrics_source = read_source(metrics_path)
    provenance_text, provenance_source = read_source(provenance_path)
    client, provenance = json.loads(client_text), json.loads(provenance_text)
    if not isinstance(client, dict) or not isinstance(provenance, dict):
        raise ValueError("Client result and provenance must be JSON objects")
    required = (
        "run_id",
        "client_host",
        "server_host",
        "runtime_version",
        "model_revision",
        "metrics_captured_at",
    )
    if any(not isinstance(provenance.get(k), str) or not provenance[k].strip() for k in required):
        raise ValueError("Provenance requires " + ", ".join(required))
    if provenance.get("format") != "vllm-bench-serve-detailed-v0.12":
        raise ValueError(
            "Unsupported format; this importer validates vLLM 0.12 detailed-result arrays"
        )
    keys = ("input_lens", "output_lens", "ttfts", "itls", "errors")
    if any(not isinstance(client.get(k), list) for k in keys):
        raise ValueError("Detailed per-request arrays required; use --save-result --save-detailed")
    count = len(client["input_lens"])
    if not 1 <= count <= MAX_REQUESTS or any(len(client[k]) != count for k in keys):
        raise ValueError("Per-request arrays must have equal lengths between 1 and 100000")
    requests = []
    for i in range(count):
        prompt = number(client["input_lens"][i], "input_lens", integer=True)
        output = number(client["output_lens"][i], "output_lens", integer=True)
        ttft = number(client["ttfts"][i], "ttfts")
        gaps = client["itls"][i]
        error = client["errors"][i]
        if not isinstance(error, str) or not isinstance(gaps, list):
            raise ValueError("Errors must be strings and ITLs must be arrays")
        for gap in gaps:
            number(gap, "itls")
        # Some endpoints export zero when streaming timing is unavailable. Never
        # turn that placeholder (or a failed request) into a zero-latency success.
        observable = not error and output > 0 and ttft > 0
        requests.append(
            {
                "source_index": i,
                "identity_provenance": "source array index; no server request ID",
                "scope": "remote_client_observation",
                "status": "error" if error else "reported_success",
                "prompt_tokens": prompt,
                "output_tokens": output,
                "client_ttft_seconds": ttft if observable else None,
                "stream_chunk_gaps_seconds": gaps if observable else None,
                "client_e2e_seconds": None,
                "server_prefill_seconds": None,
                "server_decode_seconds": None,
            }
        )
    completed = number(client.get("completed"), "completed", integer=True)
    if completed != sum(not e for e in client["errors"]):
        raise ValueError("Completed count disagrees with per-request errors; status is ambiguous")
    runtime = []
    for line_number, line in enumerate(metrics_text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = SERIES.fullmatch(line)
        if not match:
            raise ValueError(f"Invalid Prometheus sample on line {line_number}")
        series, raw, timestamp = match.groups()
        value = float(raw)
        runtime.append(
            {
                "series": series,
                "value": value if math.isfinite(value) else None,
                "nonfinite_value": raw if not math.isfinite(value) else None,
                "source_line": line_number,
                "timestamp_ms": int(timestamp) if timestamp else None,
                "scope": "remote_runtime_aggregate_snapshot",
                "host": provenance["server_host"],
            }
        )
    if not runtime:
        raise ValueError("Runtime metrics source contains no samples")
    aggregate = {}
    for key in (
        "duration",
        "completed",
        "failed",
        "total_input_tokens",
        "total_output_tokens",
        "request_throughput",
        "output_throughput",
        "total_token_throughput",
    ):
        if key in client:
            aggregate[key] = number(client[key], key)
    return {
        "schema_version": 1,
        "kind": "loupe_offline_serving_evidence",
        "provenance": {k: provenance[k] for k in (*required, "format")},
        "sources": {
            "client": client_source,
            "runtime": metrics_source,
            "provenance": provenance_source,
        },
        "requests": requests,
        "client_aggregate": aggregate,
        "runtime_aggregate": runtime,
        "limitations": [
            "Offline import; source association and host labels are operator supplied, not independently verified.",
            "Client durations are not synchronized with server clocks or local mach_continuous time.",
            "ITLs describe streamed chunks; a chunk can contain multiple tokens. E2E is unavailable in this source format.",
            "Aggregate histogram buckets do not establish per-request prefill or decode time.",
            "Runtime metrics are a cumulative snapshot, not deltas or exclusively this run's observations.",
            "Remote GPU/cache metrics are never local Mac memory samples. No local timeline is synthesized.",
            "Prompt text, generated text, and raw error messages are intentionally absent from this report.",
        ],
    }


def csv_report(report):
    buffer = io.StringIO()
    writer = csv.writer(buffer)

    def row(*cells):
        values = ["" if c is None else str(c) for c in cells]
        writer.writerow(
            ["'" + v if v.lstrip().startswith(("=", "+", "-", "@")) else v for v in values]
        )

    row("record_type", "scope", "key", "value", "source_index", "source_sha256")
    for key, value in report["provenance"].items():
        row(
            "provenance",
            "operator_supplied",
            key,
            value,
            None,
            report["sources"]["provenance"]["sha256"],
        )
    for request in report["requests"]:
        for key, value in request.items():
            if key not in ("source_index", "scope", "identity_provenance"):
                row(
                    "request",
                    request["scope"],
                    key,
                    json.dumps(value, allow_nan=False),
                    request["source_index"],
                    report["sources"]["client"]["sha256"],
                )
    for key, value in report["client_aggregate"].items():
        row(
            "aggregate",
            "remote_client_benchmark",
            key,
            value,
            None,
            report["sources"]["client"]["sha256"],
        )
    for sample in report["runtime_aggregate"]:
        row(
            "aggregate",
            sample["scope"],
            sample["series"],
            sample["value"] if sample["value"] is not None else sample["nonfinite_value"],
            sample["source_line"],
            report["sources"]["runtime"]["sha256"],
        )
    for note in report["limitations"]:
        row("limitation", "report", "note", note, None, None)
    return buffer.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("client", "metrics", "provenance", "out"):
        parser.add_argument("--" + flag, type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        report = import_report(args.client, args.metrics, args.provenance)
        args.out.mkdir(parents=True, exist_ok=False)
        (args.out / "serving.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        (args.out / "serving.csv").write_text(csv_report(report))
    except (ValueError, OSError, TypeError) as error:
        parser.exit(2, f"Import failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
