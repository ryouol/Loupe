"""Offline serving evidence import. Never fabricate local telemetry or prefill.

Input is Loupe serving-capture/v1, a normalized client capture contract for
vLLM/Unrender. It is not an arbitrary vLLM benchmark JSON parser. See docs.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from collections import Counter
from pathlib import Path

MAX_BYTES = 16 * 1024 * 1024


def number(value: object, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be numeric")
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"{name} must be finite and nonnegative")
    return value


def import_capture(capture: dict) -> dict:
    if not isinstance(capture, dict) or capture.get("schema") != "loupe-serving-capture/v1":
        raise ValueError("unsupported serving capture schema")
    provenance = capture.get("provenance")
    required = ["runtime", "runtime_version", "model_revision", "hardware", "workload_sha256"]
    if not isinstance(provenance, dict) or any(
        not isinstance(provenance.get(k), str) or not 1 <= len(provenance[k].strip()) <= 1024
        for k in required
    ):
        raise ValueError("complete serving provenance is required")
    sha = provenance["workload_sha256"]
    if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha.lower()):
        raise ValueError("invalid workload hash")
    # All timings are relative to ONE client's monotonic experiment origin.
    duration = number(capture.get("duration_ms"), "duration_ms")
    if duration <= 0:
        raise ValueError("duration must be positive")
    requests = capture.get("requests")
    if not isinstance(requests, list) or not 1 <= len(requests) <= 100000:
        raise ValueError("requests must contain 1..100000 rows")
    rows, seen = [], set()
    for request in requests:
        if not isinstance(request, dict):
            raise ValueError("request must be an object")
        rid = request.get("id")
        if not isinstance(rid, str) or not 1 <= len(rid) <= 128 or rid in seen:
            raise ValueError("request IDs must be bounded and unique")
        seen.add(rid)
        status = request.get("status")
        if status not in {"ok", "error", "timeout", "cancelled", "rejected"}:
            raise ValueError("unknown request status")
        start = number(request.get("start_ms"), "start_ms")
        end = number(request.get("end_ms"), "end_ms")
        tokens = number(request.get("output_tokens"), "output_tokens")
        if not isinstance(tokens, int) or tokens > 1000000 or not start <= end <= duration:
            raise ValueError("invalid request duration/token count")
        first = request.get("first_token_ms")
        if first is not None:
            first = number(first, "first_token_ms")
            if not start <= first <= end or tokens == 0:
                raise ValueError("first token outside request interval")
        if status == "ok" and (tokens == 0 or first is None):
            raise ValueError("successful generation requires output and TTFT")
        rows.append(
            {
                "id": rid,
                "status": status,
                "output_tokens": tokens,
                "ttft_ms": first - start if first is not None else None,
                "end_to_end_ms": end - start,
                "prefill_ms": None,
                "decode_tokens_per_second": None,
            }
        )
    good = [r for r in rows if r["status"] == "ok"]
    ttfts = sorted(r["ttft_ms"] for r in good)
    aggregates = capture.get("server_aggregate_metrics", {})
    if not isinstance(aggregates, dict) or len(aggregates) > 256:
        raise ValueError("at most 256 server aggregate metrics")
    for key, value in aggregates.items():
        if not isinstance(key, str) or len(key) > 128:
            raise ValueError("invalid aggregate metric name")
        number(value, key)
    return {
        "schema": "loupe-serving-report/v1",
        "provenance": provenance,
        "scope": "remote serving; client timings; server aggregates are not per-request samples",
        "duration_ms": duration,
        "outcomes": dict(Counter(r["status"] for r in rows)),
        "successful_requests_per_second": len(good) / (duration / 1000),
        "successful_output_tokens_per_second": sum(r["output_tokens"] for r in good)
        / (duration / 1000),
        "ttft_p50_ms": ttfts[math.ceil(len(ttfts) * 0.5) - 1] if ttfts else None,
        "ttft_p99_ms": ttfts[math.ceil(len(ttfts) * 0.99) - 1] if len(ttfts) >= 1000 else None,
        "server_aggregate_metrics": aggregates,
        "requests": rows,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True, help="new report directory")
    args = parser.parse_args(argv)
    with args.input.open("rb") as f:
        raw = f.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        parser.error("capture exceeds 16 MiB")
    try:
        report = import_capture(json.loads(raw))
    except (ValueError, AttributeError) as error:
        parser.error(str(error))
    report["source_sha256"] = hashlib.sha256(raw).hexdigest()
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    with (args.out / "requests.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(report["requests"][0]))
        writer.writeheader()
        for row in report["requests"]:
            row = dict(row)
            if row["id"].lstrip().startswith(("=", "+", "-", "@")):
                row["id"] = "'" + row["id"]
            writer.writerow(row)
    print(f"Imported {len(report['requests'])} requests; no local telemetry synthesized")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
