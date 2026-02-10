# semantic-aqo-lab

Lab environment for building, testing, and feeding data into the **Semantic AQO** PostgreSQL extension. This repo provides setup scripts to compile PostgreSQL 15 with the AQO extension from source, and a Python ingestion pipeline that loads sense embeddings into PostgreSQL using Product Quantization (PQ) with post-verification.

## Overview

Semantic AQO is a PostgreSQL extension that optimises query execution by learning from query patterns and adapting strategies based on semantic understanding of the workload. This lab repo covers two concerns:

1. **Environment setup** — scripts to install system dependencies, build PostgreSQL 15 from source, and compile the Semantic AQO extension.
2. **Embedding ingestion** — a Python pipeline that reads a custom binary model (`sense_embeddings.bin`), trains a FAISS Product Quantizer, and loads both raw vectors and compressed PQ codes into PostgreSQL for fast approximate nearest-neighbour search with exact post-verification.

## Repository Structure

```
semantic-aqo-lab/
├── README.md
├── src/
│   ├── scripts/                        # Environment setup (run in order)
│   │   ├── 00-system-setup.sh          # apt packages, Python 3, venv
│   │   ├── 01-postgres-clone-and-build.sh  # Download & compile PG 15
│   │   ├── 02-semantic-aqo-clone-and-build.sh  # Clone & build AQO extension
│   │   └── setup-all.sh                # Run all scripts in sequence
│   ├── ingestion/                      # Embedding ingestion pipeline
│   │   ├── main.py                     # CLI entry point (ingest / search)
│   │   ├── sense_embeddings_reader.py  # Binary parser for .bin model files
│   │   ├── pq_trainer.py              # FAISS PQ training & encoding
│   │   ├── db_schema.py               # PostgreSQL schema management
│   │   ├── db_importer.py             # Batch insert to DB
│   │   ├── search.py                  # PQ search + post-verification
│   │   ├── config/                    # JSON configs (db, pq params)
│   │   └── requirements.txt
│   ├── postgresql-15.15/              # PG source (created by scripts)
│   └── ingestion/models/             # Binary model files (.bin)
├── index_creation/                    # Reference FREDDY index code
```

## Getting Started

### 1. Environment Setup

```bash
# Run all setup scripts in order (system deps → PG build → AQO extension)
cd src/scripts
bash setup-all.sh

# Or run individually:
bash 00-system-setup.sh        # Install build tools, Python 3, venv
bash 01-postgres-clone-and-build.sh   # Download & compile PostgreSQL 15
bash 02-semantic-aqo-clone-and-build.sh  # Clone & build Semantic AQO
```

### 2. Embedding Ingestion

```bash
cd src/ingestion

# Create virtual environment & install dependencies
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Edit configs
#   config/db_config.json   → PostgreSQL credentials
#   config/pq_config.json   → path to sense_embeddings.bin, PQ parameters

# Run the full ingestion pipeline
python main.py ingest

# Search for similar senses
python main.py search SELECT
```

## Ingestion Pipeline

The pipeline follows the FREDDY architecture with a two-phase search approach:

| Step                  | Description                                                               |
| --------------------- | ------------------------------------------------------------------------- |
| 1. Read binary        | Parse `sense_embeddings.bin` → numpy arrays + `(word, sense_id)` metadata |
| 2. Create schema      | `sense_vectors_raw`, `pq_codebook`, `pq_quantization` tables              |
| 3. Import raw vectors | Full-precision vectors for post-verification                              |
| 4. Train PQ           | FAISS `ProductQuantizer` — split dimensions into subspaces                |
| 5. Encode             | Compress each vector to a compact PQ code (uint8 array)                   |
| 6. Import PQ data     | Codebook centroids + PQ codes into PostgreSQL                             |
| 7. Build indexes      | B-tree indexes on `word` and `id` columns                                 |

### Two-Phase Search

- **Phase 1 — PQ approximate**: precomputed distance lookup table → score all PQ codes → top-N candidates (default 50)
- **Phase 2 — Post-verification**: fetch raw float32 vectors for candidates → exact L2 distance → top-K results (default 5)

## Features

- PostgreSQL 15 compiled from source with Semantic AQO extension
- Custom binary model reader for `sense_embeddings.bin` (word + sense_id + vector)
- Product Quantization via FAISS for fast approximate search
- Post-verification with exact distance for high accuracy
- Batch import with bytea storage (FREDDY-compatible)
- Automatic training data augmentation when dataset is small
