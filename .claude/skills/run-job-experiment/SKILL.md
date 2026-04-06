---
name: run-job-experiment
description: Run the JOB (Join Order Benchmark) evaluation — 3-way comparison of no_aqo vs standard_aqo vs semantic_aqo over 15 iterations with chart generation.
user-invocable: true
allowed-tools: ["Bash"]
---

# Run JOB Experiment

Run the Join Order Benchmark (JOB) evaluation to compare cardinality estimation across three optimizer modes.

## Prerequisites

- PostgreSQL is running with AQO extension loaded
- `imdb` database exists and is populated (the JOB schema)
- Dev environment fully set up (see `dev-container-setup` skill)

## Run

```bash
bash src/experiment/job/run.sh
```

### Optional Flags

| Flag | Effect |
|------|--------|
| `ITERATIONS=N` | Override default 15 iterations (env var) |
| `--force` | Re-run even if previous results exist |
| `--modes "no_aqo standard_aqo semantic_aqo"` | Select which modes to run |

Examples:

```bash
# Quick 5-iteration test
ITERATIONS=5 bash src/experiment/job/run.sh

# Force re-run with all modes
bash src/experiment/job/run.sh --force

# Run only semantic_aqo mode
bash src/experiment/job/run.sh --modes "semantic_aqo"
```

## What It Does

1. **runner.py** executes 113 JOB queries × N iterations × 3 modes:
   - `no_aqo` — Baseline PostgreSQL optimizer (AQO disabled)
   - `standard_aqo` — Original AQO extension with `aqo.mode = 'learn'`
   - `semantic_aqo` — Semantic AQO with Word2Vec-enhanced cardinality estimation
2. **analyze.py** generates comparison charts from the CSV results

For each query in each iteration, it runs `EXPLAIN (ANALYZE, FORMAT JSON)` and captures:
- Execution time (ms)
- Planning time (ms)
- Cardinality Q-error (geometric mean of estimated/actual row ratios across plan nodes)

## Output

Results are written to `src/experiment/job/results/`:

| File | Contents |
|------|----------|
| `no_aqo_results.csv` | Baseline measurements |
| `standard_aqo_results.csv` | Standard AQO measurements |
| `semantic_aqo_results.csv` | Semantic AQO measurements |
| `*.png` | Comparison charts (Q-error, planning time, execution time over iterations) |

## Interpreting Results

- **Q-error chart**: Lower is better. Shows how estimation accuracy improves over iterations.
- **Planning time chart**: Semantic AQO has higher planning overhead (W2V lookup). Should be offset by execution gains.
- **Execution time chart**: Better estimates → better plans → lower execution time. The "learning curve" should show convergence.
