"""Plot saved medians and observed ranges; requires matplotlib (plotting only)."""

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("capture", type=Path)
parser.add_argument("out", type=Path)
args = parser.parse_args()
data = json.loads((args.capture / "summary.json").read_text())["conditions"]
fig, axes = plt.subplots(1, 2, figsize=(10, 4), sharey=True)
for axis, output in zip(axes, [32, 128], strict=True):
    for step, color in [(64, "#9467bd"), (512, "#167d9a")]:
        rows = sorted(
            [r for r in data if r["output_limit"] == output and r["prefill_step"] == step],
            key=lambda r: r["context_tokens"],
        )
        values = [r["client_ttft_ms"] for r in rows]
        axis.errorbar(
            [r["context_tokens"] for r in rows],
            [v["median"] for v in values],
            yerr=[
                [v["median"] - v["min"] for v in values],
                [v["max"] - v["median"] for v in values],
            ],
            marker="o",
            capsize=4,
            color=color,
            label=f"Prefill step {step}",
        )
    axis.set(title=f"{output} output-token limit", xlabel="Prompt tokens", ylim=(0, None))
    axis.grid(alpha=0.2)
axes[0].set_ylabel("Client TTFT (ms)")
axes[1].legend()
fig.suptitle("Qwen2.5 0.5B 4-bit · M1 Pro · median and range of 3 runs")
fig.tight_layout()
fig.savefig(args.out, metadata={"Creator": "Loupe saved-evidence plot"})
