# AQO (Adaptive Query Optimization) Learning Report

## Overview

AQO is a PostgreSQL extension that enhances the standard cost-based query optimizer by using machine learning to improve cardinality estimation. It collects query execution statistics and builds ML models to predict more accurate cardinalities for future query planning.

---

## PostgreSQL APIs Used

### 1. Hook System
AQO leverages PostgreSQL's extensible hook architecture:
- **`planner_hook`**: Intercepts query planning to determine ML settings and predict cardinalities
- **`ExecutorStart_hook`**: Initializes statistics collection before query execution
- **`ExecutorRun_hook`**: Monitors execution progress
- **`ExecutorEnd_hook`**: Collects final execution statistics for ML training
- **`ExplainOnePlan_hook`**: Adds AQO-specific information to EXPLAIN output

### 2. GUC (Grand Unified Configuration) System
Custom configuration parameters defined via:
- `DefineCustomEnumVariable()`: For mode selection (intelligent, forced, controlled, learn, frozen, disabled)
- `DefineCustomBoolVariable()`: For boolean flags (show_hash, show_details, learn_statement_timeout)
- `DefineCustomIntVariable()`: For numeric settings (join_threshold, fs_max_items, aqo_k)
- `DefineCustomRealVariable()`: For floating-point parameters (confidence_threshold)

### 3. Shared Memory Management
- `shmem_request_hook`: Requests shared memory allocation at startup
- HTAB hash tables for storing query statistics, data, and texts
- DSA (Dynamic Shared Memory Area) for variable-size data storage

### 4. Memory Context System
Custom memory contexts for lifecycle management:
- `AQOTopMemCtx`: Top-level AQO memory context
- `AQOCacheMemCtx`: Query environment caching (released per transaction)
- `AQOPredictMemCtx`: Prediction data (released after planning)
- `AQOLearnMemCtx`: Learning data (released after ML updates)
- `AQOStorageMemCtx`: Storage operations

### 5. Query Environment API
- `QueryEnvironment`: Stores AQO-related data alongside query execution
- Used to pass prediction/learning context between planning and execution stages

---

## System Architecture

### Core Workflow
```
Query → Preprocessing → Planning (with ML prediction) → Execution → Postprocessing (ML learning)
```

### Key Components

| Module | Responsibility |
|--------|----------------|
| `preprocessing.c` | Query classification, determines use_aqo/learn_aqo settings |
| `cardinality_hooks.c` | Intercepts cardinality estimation, applies ML predictions |
| `machine_learning.c` | k-NN regression algorithm for cardinality prediction |
| `postprocessing.c` | Collects execution statistics, updates ML models |
| `storage.c` | Persistent storage of ML models and query metadata |
| `hash.c` | Query fingerprinting (same structure = same hash) |

### Machine Learning Approach
- **Algorithm**: k-Nearest Neighbors (k-NN) regression with k=30
- **Features**: Logarithms of clause selectivities
- **Target**: Logarithm of actual cardinality
- **Distance Metrics**: Euclidean (default), Manhattan, Cosine
- **Confidence Gating**: Prediction confidence based on model maturity and neighbor consistency

---

## Key Concepts

1. **Query Hash**: Identifies query structure (constants ignored). Same structure → same hash
2. **Feature Space (FS)**: Collection of ML models for related queries
3. **Feature Subspace (FSS)**: Specific model for nodes with identical base relations and clause patterns
4. **Auto-tuning**: Automatically adjusts AQO usage based on performance feedback

## Operating Modes

| Mode | Behavior |
|------|----------|
| `intelligent` | Auto-creates feature spaces with auto-tuning enabled |
| `learn` | Same as intelligent, but auto-tuning disabled |
| `forced` | All queries share common feature space (FS=0) |
| `controlled` | Manual configuration only |
| `frozen` | Use existing models, no learning |
| `disabled` | AQO completely disabled |

---

## Extension Registration

The extension initializes via `_PG_init()` which:
1. Validates shared_preload_libraries requirement
2. Registers all GUC parameters
3. Initializes shared memory structures
4. Registers all hook functions
5. Creates memory contexts
6. Registers resource release callbacks

---

*Report Date: March 2026*
