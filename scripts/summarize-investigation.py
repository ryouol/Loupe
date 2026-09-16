"""Summarize saved client measurements; never include warmups/profiled requests."""

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("capture", type=Path)
args = parser.parse_args()
rows = json.loads((args.capture / "client.json").read_text())
groups = defaultdict(list)
for row in rows:
    if row["phase"] == "measured":
        if not row.get("timing_verified") or row["finish_reason"] not in {"stop", "eos", "length"}:
            raise ValueError("unverified measured request")
        groups[row["context_tokens"], row["output_limit"], row["prefill_step"]].append(row)

summary = []
for (context, output, step), group in sorted(groups.items()):
    item = {
        "context_tokens": context,
        "output_limit": output,
        "prefill_step": step,
        "n": len(group),
    }
    for key in ["client_ttft_ms", "client_total_ms", "peak_allocator_bytes"]:
        values = [r[key] for r in group]
        item[key] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
    comparison = [
        r
        for r in rows
        if r["phase"] == "measured"
        and r["context_tokens"] == context
        and r["output_limit"] == output
    ]
    item["identical_output_token_ids_across_steps_and_repeats"] = (
        len({r["output_token_ids_sha256"] for r in comparison}) == 1
    )
    summary.append(item)

with (args.capture / "summary.json").open("x") as f:
    json.dump(
        {"scope": "local synthetic prompts; no task-accuracy claim", "conditions": summary},
        f,
        indent=2,
    )
    f.write("\n")
print("context output step n median_TTFT_ms median_total_ms identical_tokens")
for item in summary:
    print(
        item["context_tokens"],
        item["output_limit"],
        item["prefill_step"],
        item["n"],
        round(item["client_ttft_ms"]["median"], 2),
        round(item["client_total_ms"]["median"], 2),
        item["identical_output_token_ids_across_steps_and_repeats"],
    )
