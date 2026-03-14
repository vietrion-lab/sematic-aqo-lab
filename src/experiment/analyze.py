#!/usr/bin/env python3
"""
analyze.py — Generate research-quality figures from AQO experiment results.

Reads up to 3 result CSVs (whichever exist):
  no_aqo_results.csv
  standard_aqo_results.csv
  semantic_aqo_results.csv

Produces 3 figures (individual + combined):
  Figure 1: Cardinality Estimation Error (Q-error) over iterations
  Figure 2: Planning Time over iterations
  Figure 3: Execution Time over iterations

Usage:
    python3 analyze.py <results_dir> [--title TITLE]
"""

import argparse
import csv
import os
import sys
from collections import defaultdict
from statistics import mean

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


# ── Style per series ──────────────────────────────────────────────────────────
SERIES = [
    {
        "mode":    "no_aqo",
        "label":   "PostgreSQL (no AQO)",
        "color":   "#d62728",
        "marker":  "o",
        "ls":      "-",
    },
    {
        "mode":    "standard_aqo",
        "label":   "Standard AQO (postgrespro)",
        "color":   "#2ca02c",
        "marker":  "^",
        "ls":      "--",
    },
    {
        "mode":    "semantic_aqo",
        "label":   "Semantic AQO",
        "color":   "#1f77b4",
        "marker":  "s",
        "ls":      "-",
    },
]


def load_csv(csv_path):
    """Load a results CSV → list of dicts."""
    rows = []
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "iteration":    int(row["iteration"]),
                "query":        row["query"],
                "plan_time_ms": float(row["plan_time_ms"]),
                "exec_time_ms": float(row["exec_time_ms"]),
                "total_time_ms": float(row["total_time_ms"]),
                "avg_qerror":   float(row["avg_qerror"]),
            })
    return rows


def avg_per_iteration(rows, field):
    """Compute average of `field` across all queries, per iteration."""
    by_iter = defaultdict(list)
    for r in rows:
        by_iter[r["iteration"]].append(r[field])
    iters = sorted(by_iter.keys())
    avgs = [mean(by_iter[i]) for i in iters]
    return iters, avgs


def plot_metric(ax, loaded_series, field, ylabel, title):
    """
    Plot one metric with all available series.
    loaded_series: list of (style_dict, rows)
    """
    for style, rows in loaded_series:
        iters, vals = avg_per_iteration(rows, field)
        ax.plot(iters, vals,
                marker=style["marker"],
                color=style["color"],
                linestyle=style["ls"],
                linewidth=2,
                markersize=5,
                label=style["label"],
                alpha=0.85)

    ax.set_xlabel("Iteration", fontsize=12)
    ax.set_ylabel(ylabel, fontsize=12)
    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.legend(fontsize=10, loc="best")
    ax.grid(True, alpha=0.3)
    # x-ticks from the first series (all share same iteration count)
    if loaded_series:
        iters, _ = avg_per_iteration(loaded_series[0][1], field)
        ax.set_xticks(iters)


def print_summary(loaded_series, bench_name):
    print(f"\n{'═'*60}")
    print(f"  Analysis: {bench_name}")
    print(f"{'═'*60}")
    for style, rows in loaded_series:
        _, qerr  = avg_per_iteration(rows, "avg_qerror")
        _, plan  = avg_per_iteration(rows, "plan_time_ms")
        _, exec_ = avg_per_iteration(rows, "exec_time_ms")
        label = style["label"]
        print(f"  {label:<30} Q-err: {mean(qerr):>6.2f}  "
              f"Plan: {mean(plan):>7.2f}ms  Exec: {mean(exec_):>9.2f}ms")

    # Speedup vs no_aqo baseline
    no_aqo_rows = next((r for s, r in loaded_series if s["mode"] == "no_aqo"), None)
    if no_aqo_rows:
        _, base_exec = avg_per_iteration(no_aqo_rows, "exec_time_ms")
        base_mean = mean(base_exec)
        for style, rows in loaded_series:
            if style["mode"] == "no_aqo":
                continue
            _, exec_ = avg_per_iteration(rows, "exec_time_ms")
            speedup = base_mean / mean(exec_) if mean(exec_) > 0 else float("inf")
            sign = "↑" if speedup >= 1.0 else "↓"
            print(f"  {style['label']:<30} Exec speedup vs no_aqo: {speedup:.2f}× {sign}")
    print(f"{'═'*60}")


def main():
    parser = argparse.ArgumentParser(description="AQO 3-way Experiment Analysis")
    parser.add_argument("results_dir", help="Directory containing result CSVs")
    parser.add_argument("--title", default="", help="Benchmark name for figure titles")
    args = parser.parse_args()

    results_dir = args.results_dir
    bench_name = args.title or os.path.basename(results_dir.rstrip("/"))

    # ── Load whichever CSVs exist ─────────────────────────────────────────────
    loaded_series = []
    for style in SERIES:
        csv_path = os.path.join(results_dir, f"{style['mode']}_results.csv")
        if os.path.exists(csv_path):
            rows = load_csv(csv_path)
            loaded_series.append((style, rows))
            print(f"  Loaded: {style['mode']} ({len(rows)} rows)")
        else:
            print(f"  Skip  : {style['mode']} (not found: {csv_path})")

    if not loaded_series:
        print(f"Error: no result CSVs found in {results_dir}")
        sys.exit(1)

    print_summary(loaded_series, bench_name)

    # ── Combined figure (3 panels) ────────────────────────────────────────────
    fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(20, 5))
    fig.suptitle(f"AQO 3-Way Experiment — {bench_name}", fontsize=14, fontweight="bold")

    plot_metric(ax1, loaded_series, "avg_qerror",
                ylabel="Avg Q-error (geometric mean)",
                title="Cardinality Estimation Accuracy")

    plot_metric(ax2, loaded_series, "plan_time_ms",
                ylabel="Avg Planning Time (ms)",
                title="Planning Time")

    plot_metric(ax3, loaded_series, "exec_time_ms",
                ylabel="Avg Execution Time (ms)",
                title="Execution Time")

    plt.tight_layout()
    fig_path = os.path.join(results_dir, f"figures_{bench_name}.png")
    fig.savefig(fig_path, dpi=150, bbox_inches="tight")
    print(f"\n  Figures saved: {fig_path}")
    plt.close(fig)

    # ── Individual figures ────────────────────────────────────────────────────
    metrics = [
        ("avg_qerror",   "Avg Q-error (geometric mean)",  "Cardinality Estimation Accuracy", f"fig1_cardinality_{bench_name}.png"),
        ("plan_time_ms", "Avg Planning Time (ms)",         "Planning Time",                   f"fig2_planning_time_{bench_name}.png"),
        ("exec_time_ms", "Avg Execution Time (ms)",        "Execution Time",                  f"fig3_execution_time_{bench_name}.png"),
    ]
    for field, ylabel, title_str, fname in metrics:
        fig_s, ax = plt.subplots(figsize=(8, 5))
        plot_metric(ax, loaded_series, field,
                    ylabel=ylabel,
                    title=f"{title_str} — {bench_name}")
        out = os.path.join(results_dir, fname)
        fig_s.savefig(out, dpi=150, bbox_inches="tight")
        plt.close(fig_s)
        print(f"  {fname}")


if __name__ == "__main__":
    main()
