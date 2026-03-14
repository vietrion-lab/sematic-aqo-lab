#!/usr/bin/env python3
"""
runner.py — Core AQO experiment engine.

Runs a benchmark (set of SQL queries) in THREE modes:
  1. no_aqo:       AQO disabled, default PostgreSQL optimizer
  2. standard_aqo: postgrespro/aqo (stable15) in learn mode — activated via switch-aqo.sh
  3. semantic_aqo: Semantic AQO (w2v embeddings) in learn mode — activated via switch-aqo.sh

For each iteration × query, captures:
  - Planning time (ms)
  - Execution time (ms)
  - Cardinality Q-error per plan node → averaged per query

Outputs CSVs:
  no_aqo_results.csv
  standard_aqo_results.csv
  semantic_aqo_results.csv

Usage:
    python3 runner.py <db_name> <query_dir> <results_dir> [--iterations N] [--force]
                      [--modes no_aqo,standard_aqo,semantic_aqo]

Checkpoint / Resume:
    After each phase completes, a .done marker is written.
    On re-run, completed phases are automatically skipped.
    Use --force to discard previous results and re-run everything.

switch-aqo.sh:
    The standard_aqo and semantic_aqo phases require switch-aqo.sh to be
    reachable at SWITCH_AQO (env var) or auto-detected relative to this script.
    Set SWITCH_AQO_SKIP=1 to skip the switch step (if only one AQO variant
    is installed and you want to run just two modes).
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
SWITCH_AQO_SKIP = os.environ.get("SWITCH_AQO_SKIP", "0") == "1"

# Auto-detect switch-aqo.sh location:
#   - SWITCH_AQO env var override
#   - sibling scripts/ directory next to runner.py (experiment/../scripts/)
_runner_dir = Path(__file__).resolve().parent
_default_switch = _runner_dir.parent / "scripts" / "switch-aqo.sh"
SWITCH_AQO = os.environ.get("SWITCH_AQO", str(_default_switch))

# Which modes to run (can be overridden via --modes CLI flag)
ALL_MODES = ["no_aqo", "standard_aqo", "semantic_aqo"]


def run_psql(db, sql):
    """Execute SQL via psql, return stdout."""
    parts = PSQL.split()
    cmd = parts + ["-d", db, "-t", "-A", "-c", sql]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def run_psql_file(db, filepath):
    """Execute a SQL file via psql, return stdout."""
    parts = PSQL.split()
    cmd = parts + ["-d", db, "-t", "-A", "-f", filepath]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def switch_aqo_variant(variant):
    """
    Call switch-aqo.sh to swap the active AQO .so.
    variant: 'standard' | 'semantic'
    Returns True on success.
    """
    if SWITCH_AQO_SKIP:
        print(f"    [SWITCH_AQO_SKIP=1] Skipping AQO switch to '{variant}'")
        return True

    if not os.path.exists(SWITCH_AQO):
        print(f"  ⚠️  switch-aqo.sh not found at {SWITCH_AQO}", file=sys.stderr)
        print("     Set SWITCH_AQO env var or run 04-standard-aqo-build.sh first.", file=sys.stderr)
        return False

    print(f"\n  🔄 Switching AQO variant → {variant} ...")
    result = subprocess.run(
        ["bash", SWITCH_AQO, variant],
        capture_output=False,  # let it print to terminal (shows pg_ctl output)
        text=True,
    )
    if result.returncode != 0:
        print(f"  ❌ switch-aqo.sh failed (exit {result.returncode})", file=sys.stderr)
        return False

    print(f"  ✅ AQO variant switched to: {variant}")
    return True


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


def build_guc(mode):
    """
    Return the GUC SET preamble for a given mode.

    no_aqo:       AQO disabled entirely
    standard_aqo: AQO in learn mode (standard postgrespro/aqo behaviour)
    semantic_aqo: AQO in learn mode (semantic-aqo — same GUCs, different .so)
    """
    if mode == "no_aqo":
        guc = "SET aqo.mode = 'disabled';\n"
        guc += "SET aqo.force_collect_stat = 'on';\n"
    elif mode in ("standard_aqo", "semantic_aqo"):
        guc = "SET aqo.mode = 'learn';\n"
        guc += f"SET aqo.join_threshold = {AQO_JOIN_THRESHOLD};\n"
        guc += "SET aqo.force_collect_stat = 'on';\n"
    else:
        raise ValueError(f"Unknown mode: {mode}")
    return guc


def run_phase(db, queries, results_dir, mode, iterations):
    """
    Run a phase of the experiment.

    mode: 'no_aqo' | 'standard_aqo' | 'semantic_aqo'
    """
    csv_path = os.path.join(results_dir, f"{mode}_results.csv")
    guc = build_guc(mode)

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

    # Write checkpoint marker
    done_path = os.path.join(results_dir, f"{mode}.done")
    with open(done_path, "w") as f:
        f.write(f"{iterations}\n")
    print(f"  ✓ Checkpoint saved: {done_path}")
    return csv_path


def phase_is_done(results_dir, mode, iterations):
    """Check if a phase was already completed with the same iteration count."""
    done_path = os.path.join(results_dir, f"{mode}.done")
    csv_path = os.path.join(results_dir, f"{mode}_results.csv")
    if not os.path.exists(done_path) or not os.path.exists(csv_path):
        return False
    try:
        with open(done_path) as f:
            saved_iters = int(f.read().strip())
        return saved_iters == iterations
    except (ValueError, OSError):
        return False


def main():
    parser = argparse.ArgumentParser(description="AQO Experiment Runner (3-way)")
    parser.add_argument("db", help="Database name")
    parser.add_argument("query_dir", help="Directory containing .sql query files")
    parser.add_argument("results_dir", help="Directory to write results")
    parser.add_argument("--iterations", type=int, default=15,
                        help="Iterations per mode (default: 15)")
    parser.add_argument("--force", action="store_true",
                        help="Ignore checkpoints, re-run everything")
    parser.add_argument("--modes", default=",".join(ALL_MODES),
                        help=f"Comma-separated list of modes to run (default: {','.join(ALL_MODES)})")
    args = parser.parse_args()

    selected_modes = [m.strip() for m in args.modes.split(",")]
    for m in selected_modes:
        if m not in ALL_MODES:
            print(f"Unknown mode: {m}. Must be one of: {', '.join(ALL_MODES)}")
            sys.exit(1)

    queries = collect_queries(args.query_dir)
    if not queries:
        print(f"No .sql files found in {args.query_dir}")
        sys.exit(1)

    os.makedirs(args.results_dir, exist_ok=True)

    print("╔═══════════════════════════════════════════════════════╗")
    print(f"║  AQO Experiment: {args.db:<38}║")
    print(f"║  Queries : {len(queries):<43}║")
    print(f"║  Iters   : {args.iterations:<43}║")
    print(f"║  Modes   : {', '.join(selected_modes):<43}║")
    print("╚═══════════════════════════════════════════════════════╝")

    # Ensure AQO extension is installed in the target DB
    rc, _, _ = run_psql(args.db, "CREATE EXTENSION IF NOT EXISTS aqo;")
    if rc != 0:
        print("ERROR: Failed to create AQO extension")
        sys.exit(1)

    # Remove old checkpoints if --force
    if args.force:
        for mode in selected_modes:
            done = os.path.join(args.results_dir, f"{mode}.done")
            if os.path.exists(done):
                os.remove(done)
                print(f"  Removed checkpoint: {done}")

    # ── Run each mode in order ────────────────────────────────────────────────
    for mode in selected_modes:
        if phase_is_done(args.results_dir, mode, args.iterations):
            print(f"\n  ⏭  Phase {mode.upper()} already complete ({args.iterations} iters) — skipping")
            continue

        # Switch AQO variant if needed
        if mode == "standard_aqo":
            if not switch_aqo_variant("standard"):
                print(f"  ❌ Cannot switch to standard AQO — aborting phase {mode}")
                sys.exit(1)
            # Re-create extension (the .so may have changed)
            run_psql(args.db, "DROP EXTENSION IF EXISTS aqo CASCADE;")
            rc, _, err = run_psql(args.db, "CREATE EXTENSION aqo;")
            if rc != 0:
                print(f"  ❌ Failed to create AQO extension after switch: {err}")
                sys.exit(1)

        elif mode == "semantic_aqo":
            if not switch_aqo_variant("semantic"):
                print(f"  ❌ Cannot switch to semantic AQO — aborting phase {mode}")
                sys.exit(1)
            run_psql(args.db, "DROP EXTENSION IF EXISTS aqo CASCADE;")
            rc, _, err = run_psql(args.db, "CREATE EXTENSION aqo;")
            if rc != 0:
                print(f"  ❌ Failed to create AQO extension after switch: {err}")
                sys.exit(1)

        # Reset AQO data before each learning phase
        if mode != "no_aqo":
            run_psql(args.db, "SELECT aqo_reset();")

        run_phase(args.db, queries, args.results_dir, mode, args.iterations)

    # ── Restore semantic AQO after all phases ─────────────────────────────────
    if "standard_aqo" in selected_modes and not SWITCH_AQO_SKIP:
        print("\n  🔄 Restoring semantic AQO as default...")
        switch_aqo_variant("semantic")
        run_psql(args.db, "DROP EXTENSION IF EXISTS aqo CASCADE;")
        run_psql(args.db, "CREATE EXTENSION IF NOT EXISTS aqo;")

    print(f"\n{'═'*60}")
    print(f"  Experiment complete. Results: {args.results_dir}")
    print(f"{'═'*60}")


if __name__ == "__main__":
    main()
