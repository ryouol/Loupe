"""Exercise a running local llama-server through the real recorder and replay."""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


def capture(args, name, cancel):
    binaries = Path(".build/debug").resolve()
    output = args.output / name
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="lc-", dir="/tmp") as storage:
        recorder = subprocess.Popen(
            [str(binaries / "loupe-capture"), storage],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        adapter = None
        try:
            ready = json.loads(recorder.stdout.readline())
            env = dict(os.environ, LOUPE_SOCKET_PATH=ready["socket"], LOUPE_RUN_ID=ready["runID"])
            command = [
                str(binaries / "loupe-llamacpp"),
                "--server",
                args.server,
                "--max-tokens",
                "4096" if cancel else "128",
                "--kv-layers",
                str(args.kv_layers),
                "--kv-head-dim",
                str(args.kv_head_dim),
                "--kv-heads",
                str(args.kv_heads),
                "--kv-bytes-per-element",
                "2",
                "--prompt-stdin",
            ]
            adapter = subprocess.Popen(
                command,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            prompt = (
                "<|im_start|>user\nWrite a long numbered list of facts about astronomy."
                "<|im_end|>\n<|im_start|>assistant\n"
            )
            adapter.stdin.write(prompt)
            adapter.stdin.close()
            adapter.stdin = None
            if cancel:
                time.sleep(0.3)
                assert adapter.poll() is None, "Request finished before cancellation"
                adapter.terminate()
            _, diagnostic = adapter.communicate(timeout=60)
            (output / "adapter.txt").write_text(diagnostic)
            assert adapter.returncode == (-15 if cancel else 0), diagnostic
            time.sleep(0.3)
            _, diagnostic = recorder.communicate("\n", timeout=30)
            assert recorder.returncode == 0, diagnostic
            (output / "recorder.txt").write_text(diagnostic)
            base = Path(ready["basePath"])
            for extension in (".ndjson", ".system.ndjson", ".metadata.json"):
                shutil.copyfile(str(base) + extension, output / ("session" + extension))
            subprocess.run(
                [str(binaries / "loupe-export"), str(output / "session"), str(output / "export")],
                check=True,
                timeout=30,
            )
        finally:
            for process in (adapter, recorder):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait()
    evidence = json.loads((output / "export.json").read_text())
    assert evidence["droppedEventLines"] == evidence["droppedSampleLines"] == 0
    assert evidence["sampleCount"] > 0
    assert evidence["telemetryAcquisitionLosses"]["lowerBound"] == 0
    outcomes = evidence["requestOutcomes"]
    assert len(outcomes) == 1, outcomes
    if cancel:
        assert outcomes[0]["finishReason"] == "incomplete", outcomes
        assert evidence["requests"] == [], "Cancelled attempt must not enter completed metrics"
        assert "exact" not in evidence["eventAcquisitionLosses"]
    else:
        assert outcomes[0]["finishReason"] == "length", outcomes
        assert outcomes[0]["outputTokens"] == 128
        assert evidence["eventAcquisitionLosses"]["exact"] == 0
        assert evidence["requests"][0]["ttftNs"] > 0
    return {
        key: evidence[key]
        for key in (
            "eventCount",
            "sampleCount",
            "requestOutcomes",
            "requests",
            "eventAcquisitionLosses",
            "telemetryAcquisitionLosses",
        )
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="http://127.0.0.1:18080")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kv-layers", type=int, required=True)
    parser.add_argument("--kv-head-dim", type=int, required=True)
    parser.add_argument("--kv-heads", type=int, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = {
        name: capture(args, name, cancel)
        for name, cancel in (("completed-1", False), ("completed-2", False), ("cancelled", True))
    }
    (args.output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    print("PASS: two completed requests and one cancelled request; replay and export verified.")


if __name__ == "__main__":
    main()
