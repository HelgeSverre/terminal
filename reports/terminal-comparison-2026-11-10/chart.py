import json
import math
import re
import statistics
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    report = json.loads(Path(sys.argv[1]).read_text())
    assert report["passed"] and len(report["trials"]) == 2
    provenance = json.loads((Path(__file__).parent / "app-provenance.json").read_text())
    source = provenance["application_revision"][:7]
    ghostty_version = re.search(r"\d+\.\d+\.\d+", report["ghostty_version"]).group()
    kitty_version = re.search(r"\d+\.\d+\.\d+", report["kitty_version"]).group()
    hardware = report["hardware"].strip()
    os_version = re.search(r"ProductVersion:\s+(\S+)", report["os"]).group(1)
    power_match = re.search(r"Now drawing from '([^']+)'", report["power"])
    power = power_match.group(1) if power_match else "Power source unknown"
    workloads = [
        ("ascii_short_lines", "Short ASCII lines"),
        ("ascii_long_lines", "Long ASCII lines"),
        ("ansi_truecolor", "ANSI truecolor"),
        ("unicode", "Mixed Unicode"),
    ]
    series = [
        ("terminal", "Helge Terminal", "#facc15"),
        ("ghostty", f"Ghostty {ghostty_version}", "#4ade80"),
        ("kitty", f"Kitty {kitty_version}", "#60a5fa"),
    ]
    summary = {}
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11})
    fig, ax = plt.subplots(figsize=(12, 6.8), facecolor="#0d0d0f")
    ax.set_facecolor("#0d0d0f")
    for j, (name, label, color) in enumerate(series):
        for i, (key, _) in enumerate(workloads):
            values = []
            for trial in report["trials"]:
                app = trial["apps"][name]
                assert app["natural_exit"] and not app["cleanup_survivors"]
                workload = next(
                    w for w in app["report"]["workloads"] if w["name"] == key
                )
                assert len(workload["run_samples"]) == 10
                values.append(workload["mib_per_second"]["p50"])
            mean = statistics.mean(values)
            summary.setdefault(key, {})[name] = {
                "mean_of_trial_medians": mean,
                "trial_medians": values,
            }
            y = i * 1.65 + (j - 1) * 0.4
            ax.barh(y, mean, height=0.31, color=color, label=label if i == 0 else None)
            ax.errorbar(
                mean,
                y,
                xerr=[[mean - min(values)], [max(values) - mean]],
                fmt="none",
                ecolor="#f1f1f4",
                elinewidth=1.1,
                capsize=3,
            )
            ax.text(
                max(values) + 4,
                y,
                f"{mean:.1f}",
                va="center",
                color="#ececf1",
                fontsize=10,
            )
    ax.set_yticks([i * 1.65 for i in range(4)], [label for _, label in workloads])
    ax.invert_yaxis()
    largest = max(
        value
        for workload in summary.values()
        for app in workload.values()
        for value in app["trial_medians"]
    )
    upper = math.ceil((largest + 35) / 50) * 50
    ax.set_xlim(0, upper)
    ax.set_xticks(range(0, upper + 1, 50))
    ax.set_xlabel("MiB/s · higher is better", color="#b4b4bd", labelpad=12)
    ax.tick_params(axis="both", colors="#b4b4bd", length=0, pad=10)
    ax.grid(axis="x", color="#2a2a30", linewidth=0.8)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_visible(False)
    fig.subplots_adjust(left=0.2, right=0.94, top=0.77, bottom=0.23)
    fig.text(
        0.055,
        0.94,
        "Terminal output throughput",
        fontsize=21,
        color="#ececf1",
        weight="bold",
    )
    fig.text(
        0.055,
        0.891,
        f"{hardware} · macOS {os_version} · {power} · Swift {source}",
        fontsize=11,
        color="#b4b4bd",
    )
    fig.legend(
        loc="upper left",
        bbox_to_anchor=(0.19, 0.862),
        ncol=3,
        frameon=False,
        labelcolor="#ececf1",
        handlelength=1.2,
        columnspacing=2.2,
    )
    fig.text(
        0.055,
        0.105,
        "100×30 cells · configured Obel Mono 14 · 10×16 MiB per workload per trial · two reversed launch orders",
        color="#b4b4bd",
        fontsize=9,
    )
    fig.text(
        0.055,
        0.067,
        "Bars: mean of trial medians; whiskers: their range. PTY processing, not displayed FPS. Alternate screen excludes history.",
        color="#8a8a94",
        fontsize=8.5,
    )
    fig.text(
        0.055,
        0.035,
        "Native cell-pixel metrics differ between apps; equal cell grids do not imply equal raster workloads.",
        color="#8a8a94",
        fontsize=8.5,
    )
    destination = Path(__file__).parent
    fig.savefig(destination / "throughput.png", dpi=200, facecolor=fig.get_facecolor())
    fig.savefig(destination / "throughput.svg", facecolor=fig.get_facecolor())
    svg = destination / "throughput.svg"
    svg.write_text(
        "\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n"
    )
    (destination / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
