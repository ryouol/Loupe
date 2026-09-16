import json
import subprocess
from pathlib import Path

import pytest
from loupe_mlx import events as ev

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / ".build/debug/loupe-report"


@pytest.mark.skipif(not BINARY.exists(), reason="build loupe-report for native replay tests")
def test_native_report_rejects_overwrite_and_excludes_cancelled_requests(tmp_path):
    events = []
    for i, reason in enumerate(["length", "cancelled"]):
        rid = "q" + str(i)
        for ts, payload in [
            (100, ev.RequestStart()),
            (200, ev.PrefillEnd(prompt_tokens=4)),
            (
                300,
                ev.DecodeTick(
                    output_tokens=1,
                    active_memory_bytes=100,
                    allocator_memory_growth_bytes=0,
                    memory_provenance=ev.MemoryMetricProvenance.ALLOCATOR_DELTA_PROXY,
                ),
            ),
            (500, ev.RequestEnd(output_tokens=2, finish_reason=reason, decode_duration_ns=300)),
        ]:
            events.append(ev.encode_line(ev.Envelope(ts + i * 1000, "r", payload, request_id=rid)))
    source = tmp_path / "events.ndjson"
    source.write_bytes(b"\n".join(events))
    system = tmp_path / "system.ndjson"
    system.write_text("")
    out = tmp_path / "report"
    command = [str(BINARY), "--events", str(source), "--system", str(system), "--out", str(out)]
    subprocess.run(command, check=True, capture_output=True)
    report = json.loads((out / "report.json").read_text())
    assert len(report["requests"]) == 1
    assert report["finishReasons"] == {"length": 1, "cancelled": 1}
    assert report["sampleCount"] == 0
    assert report["requests"][0]["ttftNs"] == 200
    assert subprocess.run(command, capture_output=True).returncode == 2
