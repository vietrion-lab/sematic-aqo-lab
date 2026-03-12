#!/usr/bin/env python3
"""
runner.py — Core AQO experiment engine.

Runs a benchmark (set of SQL queries) in two modes:
  1. no_aqo:   AQO disabled, default PostgreSQL optimizer (20 iterations)
  2. with_aqo: AQO in learn mode with semantic embeddings  (20 iterations)

For each iteration × query, captures:
  - Planning time (ms)
  - Execution time (ms)
  - Cardinality Q-error per plan node → averaged per query

Outputs CSVs for analyze.py to produce figures.

Usage:
    python3 runner.py <db_name> <query_dir> <results_dir> [--iterations N]
"""

import argparse
import csv
import json
import math
import os
import subprocess
import sys
from pathlib import Path

PSQL = os.environ.get("PSQL", "sudo -u postgres /usr/local/pgsql/bin/psql")
AQO_JOIN_THRESHOLD = int(os.environ.get("AQO_JOIN_THRESHOLD", "0"))
AQO_PARALLEL_WORKERS = int(os.environ.get("AQO_PARALLEL_WORKERS", "0"))


def run_psql(db, sql):
    """Execute SQL via psql, return stdout."""
    parts = PSQL.split()
    cmd = parts + ["-d", db, "-t", "-A", "-c", sql]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode, result.stdout, result.stderr


def run_psql_file(db, filepath):
    """Execute a SQL file via psql, return stdout."""
    parts = PSQL.split()
    cmd = parts + ["-d", db, "-t", "-A", "-f", filepath]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode, result.stdout, result.stderr


def extract_qerrors(node):
    """Walk the JSON plan tree, collect Q-errors for each node."""
    qerrors = []
    est = node.get("Plan Rows", 0)
    act = node.get("Actual Rows", 0)
    if est > 0 and act > 0:
        qerrors.append(max(est / act, act / est))
    elif est == 0 and act == 0:
        qerrors.append(1.0)
    else:
        qerrors.append(max(est, act, 1))
    for child in node.get("Plans", []):
        qerrors.extend(extract_qerrors(child))
    return qerrors


def geometric_mean(values):
    """Compute geometric mean of a list of positive numbers."""
    if not values:
        return 1.0
    log_sum = sum(math.log(v) for v in values if v > 0)
    return math.exp(log_sum / len(values))


def run_explain_query(db, query_sql, guc_preamble=""):
    """Run EXPLAIN (ANALYZE, FORMAT JSON) on a query, return parsed results."""
    full_sql = guc_preamble + "EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) " + query_sql
    rc, stdout, stderr = run_psql(db, full_sql)
    if rc != 0:
        return None

    try:
        # Strip SET/other non-JSON lines — find the JSON array start
        json_start = stdout.find("[")
        if json_start < 0:
            return None
        json_text = stdout[json_start:]

        plan_json = json.loads(json_text)
        top = plan_json[0]
        plan_node = top["Plan"]
        exec_time = top.get("Execution Time", 0.0)
        plan_time = top.get("Planning Time", 0.0)
        qerrors = extract_qerrors(plan_node)
        avg_qerror = geometric_mean(qerrors)
        return {
            "exec_time": exec_time,
            "plan_time": plan_time,
            "total_time": exec_time + plan_time,
            "avg_qerror": avg_qerror,
            "n_nodes": len(qerrors),
        }
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        print(f"    JSON parse error: {e}", file=sys.stderr)
        return None


def collect_queries(query_dir):
    """Find all .sql files in a directory, sorted."""
    qdir = Path(query_dir)
    queries = {}
    for f in sorted(qdir.glob("*.sql")):
        with open(f) as fh:
            queries[f.stem] = fh.read().strip()
    return queries


def run_phase(db, queries, results_dir, mode, iterations):
    """
    Run a phase of the experiment.

    mode: 'no_aqo' or 'with_aqo'
    """
    csv_path = os.path.join(results_dir, f"{mode}_results.csv")

    # Build GUC preamble
    if mode == "no_aqo":
        guc = "SET aqo.mode = 'disabled';\n"
        guc += "SET aqo.force_collect_stat = 'on';\n"
        guc += f"SET max_parallel_workers_per_gather = {AQO_PARALLEL_WORKERS};\n"
    else:
        guc = "SET aqo.mode = 'learn';\n"
        guc += f"SET aqo.join_threshold = {AQO_JOIN_THRESHOLD};\n"
        guc += "SET aqo.force_collect_stat = 'on';\n"
        guc += f"SET max_parallel_workers_per_gather = {AQO_PARALLEL_WORKERS};\n"

    print(f"\n{'━'*60}")
    print(f"  Phase: {mode.upper()}  |  DB: {db}  |  Iterations: {iterations}")
    print(f"{'━'*60}")

    rows = []
    for i in range(1, iterations + 1):
        print(f"  ── Iteration {i}/{iterations} ──")
        for qname, qsql in sorted(queries.items()):
            result = run_explain_query(db, qsql, guc)
            if result is None:
                print(f"    SKIP {qname} (error)")
                continue

            rows.append({
                "iteration": i,
                "query": qname,
                "exec_time_ms": round(result["exec_time"], 3),
                "plan_time_ms": round(result["plan_time"], 3),
                "total_time_ms": round(result["total_time"], 3),
                "avg_qerror": round(result["avg_qerror"], 4),
            })
            print(f"    {qname:<15} total={result['total_time']:>8.2f}ms  q-err={result['avg_qerror']:>6.2f}")

    # Write CSV
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "iteration", "query", "exec_time_ms", "plan_time_ms",
            "total_time_ms", "avg_qerror"])
        writer.writeheader()
        writer.writerows(rows)

    print(f"  → {csv_path} ({len(rows)} rows)")
    return csv_path


def main():
    parser = argparse.ArgumentParser(description="AQO Experiment Runner")
    parser.add_argument("db", help="Database name")
    parser.add_argument("query_dir", help="Directory containing .sql query files")
    parser.add_argument("results_dir", help="Directory to write results")
    parser.add_argument("--iterations", type=int, default=20, help="Iterations per mode (default: 20)")
    args = parser.parse_args()

    queries = collect_queries(args.query_dir)
    if not queries:
        print(f"No .sql files found in {args.query_dir}")
        sys.exit(1)

    os.makedirs(args.results_dir, exist_ok=True)

    print("╔═══════════════════════════════════════════════════════╗")
    print(f"║  AQO Experiment: {args.db:<38}║")
    print(f"║  Queries : {len(queries):<43}║")
    print(f"║  Iters   : {args.iterations:<43}║")
    print("╚═══════════════════════════════════════════════════════╝")

    # Ensure AQO extension is installed
    rc, _, _ = run_psql(args.db, "CREATE EXTENSION IF NOT EXISTS aqo;")
    if rc != 0:
        print("ERROR: Failed to create AQO extension")
        sys.exit(1)

    # Phase 1: no_aqo — reset AQO, run with mode=disabled
    run_psql(args.db, "SELECT aqo_reset();")
    run_phase(args.db, queries, args.results_dir, "no_aqo", args.iterations)

    # Phase 2: with_aqo — reset AQO, run with mode=learn
    run_psql(args.db, "SELECT aqo_reset();")
    run_phase(args.db, queries, args.results_dir, "with_aqo", args.iterations)

    print(f"\n{'═'*60}")
    print(f"  Experiment complete. Results: {args.results_dir}")
    print(f"{'═'*60}")


if __name__ == "__main__":
    main()
