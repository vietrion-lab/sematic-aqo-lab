#!/usr/bin/env python3
"""
analyze.py — Generate research-quality figures from AQO experiment results.

Reads no_aqo_results.csv and with_aqo_results.csv, produces 3 figures:
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


def load_csv(csv_path):
    """Load a results CSV → list of dicts."""
    rows = []
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "iteration": int(row["iteration"]),
                "query": row["query"],
                "plan_time_ms": float(row["plan_time_ms"]),
                "exec_time_ms": float(row["exec_time_ms"]),
                "total_time_ms": float(row["total_time_ms"]),
                "avg_qerror": float(row["avg_qerror"]),
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


def plot_figure(ax, iters_noaqo, vals_noaqo, iters_aqo, vals_aqo,
                ylabel, title):
    """Plot a single comparison figure on the given axes."""
    ax.plot(iters_noaqo, vals_noaqo, "o-", color="#d62728", linewidth=2,
            markersize=5, label="PostgreSQL (no AQO)", alpha=0.85)
    ax.plot(iters_aqo, vals_aqo, "s-", color="#1f77b4", linewidth=2,
            markersize=5, label="Semantic AQO", alpha=0.85)

    ax.set_xlabel("Iteration", fontsize=12)
    ax.set_ylabel(ylabel, fontsize=12)
    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.legend(fontsize=10, loc="best")
    ax.grid(True, alpha=0.3)
    ax.set_xticks(iters_aqo)


def main():
    parser = argparse.ArgumentParser(description="AQO Experiment Analysis")
    parser.add_argument("results_dir", help="Directory containing result CSVs")
    parser.add_argument("--title", default="", help="Benchmark name for figure titles")
    args = parser.parse_args()

    results_dir = args.results_dir
    noaqo_path = os.path.join(results_dir, "no_aqo_results.csv")
    aqo_path = os.path.join(results_dir, "with_aqo_results.csv")

    for p in [noaqo_path, aqo_path]:
        if not os.path.exists(p):
            print(f"Error: {p} not found")
            sys.exit(1)

    noaqo_rows = load_csv(noaqo_path)
    aqo_rows = load_csv(aqo_path)
    bench_name = args.title or os.path.basename(results_dir.rstrip("/"))

    # ── Compute per-iteration averages ────────────────────────────────────
    it_n, qerr_n = avg_per_iteration(noaqo_rows, "avg_qerror")
    it_a, qerr_a = avg_per_iteration(aqo_rows, "avg_qerror")

    it_np, plan_n = avg_per_iteration(noaqo_rows, "plan_time_ms")
    it_ap, plan_a = avg_per_iteration(aqo_rows, "plan_time_ms")

    it_ne, exec_n = avg_per_iteration(noaqo_rows, "exec_time_ms")
    it_ae, exec_a = avg_per_iteration(aqo_rows, "exec_time_ms")

    # ── Print summary ─────────────────────────────────────────────────────
    print(f"\n{'═'*60}")
    print(f"  Analysis: {bench_name}")
    print(f"{'═'*60}")
    print(f"  No AQO  — Q-err: {mean(qerr_n):.2f}  Plan: {mean(plan_n):.2f}ms  Exec: {mean(exec_n):.2f}ms")
    print(f"  AQO     — Q-err: {mean(qerr_a):.2f}  Plan: {mean(plan_a):.2f}ms  Exec: {mean(exec_a):.2f}ms")
    if mean(exec_n) > 0:
        speedup = mean(exec_n) / mean(exec_a) if mean(exec_a) > 0 else float('inf')
        print(f"  Exec Speedup: {speedup:.2f}x")
    if qerr_a:
        print(f"  Q-error improvement: {qerr_a[0]:.2f} → {qerr_a[-1]:.2f}")
    print(f"{'═'*60}")

    # ── Generate Combined Figure (3 panels) ───────────────────────────────
    fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(20, 5))
    fig.suptitle(f"AQO Experiment — {bench_name}", fontsize=14, fontweight="bold")

    plot_figure(ax1, it_n, qerr_n, it_a, qerr_a,
                ylabel="Avg Q-error (geometric mean)",
                title="Cardinality Estimation Accuracy")

    plot_figure(ax2, it_np, plan_n, it_ap, plan_a,
                ylabel="Avg Planning Time (ms)",
                title="Planning Time")

    plot_figure(ax3, it_ne, exec_n, it_ae, exec_a,
                ylabel="Avg Execution Time (ms)",
                title="Execution Time")

    plt.tight_layout()

    fig_path = os.path.join(results_dir, f"figures_{bench_name}.png")
    fig.savefig(fig_path, dpi=150, bbox_inches="tight")
    print(f"\n  Figures saved: {fig_path}")
    plt.close(fig)

    # Also save individual figures for the paper
    for metric, it_ns, vals_ns, it_as, vals_as, ylabel, title_str, fname in [
        ("qerror", it_n, qerr_n, it_a, qerr_a,
         "Avg Q-error (geometric mean)",
         "Cardinality Estimation Accuracy",
         f"fig1_cardinality_{bench_name}.png"),
        ("plan", it_np, plan_n, it_ap, plan_a,
         "Avg Planning Time (ms)",
         "Planning Time",
         f"fig2_planning_time_{bench_name}.png"),
        ("exec", it_ne, exec_n, it_ae, exec_a,
         "Avg Execution Time (ms)",
         "Execution Time",
         f"fig3_execution_time_{bench_name}.png"),
    ]:
        fig_single, ax = plt.subplots(figsize=(7, 5))
        plot_figure(ax, it_ns, vals_ns, it_as, vals_as,
                    ylabel=ylabel,
                    title=f"{title_str} — {bench_name}")
        fig_single.savefig(os.path.join(results_dir, fname), dpi=150, bbox_inches="tight")
        plt.close(fig_single)
        print(f"  {fname}")


if __name__ == "__main__":
    main()
