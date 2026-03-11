#!/usr/bin/env python3
"""
Load token embeddings from sense_embeddings.bin into PostgreSQL table `token_embeddings`.

Binary format of sense_embeddings.bin:
  Header:  int32(num_tokens) | int32(vec_dim)
  Records: int32(token_len) | char[token_len] | float32[vec_dim]
"""

import configparser
import os
import struct
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, '..', 'config', 'db.conf')


def load_config():
    config = configparser.ConfigParser()
    config.read(CONFIG_PATH)
    return {
        'host': config.get('database', 'host'),
        'port': config.get('database', 'port'),
        'dbname': config.get('database', 'dbname'),
        'user': config.get('database', 'user'),
        'password': config.get('database', 'password', fallback=''),
        'pgbin': config.get('paths', 'pgbin'),
        'models_dir': config.get('paths', 'models_dir'),
    }


def parse_embeddings(bin_path):
    """Parse sense_embeddings.bin and yield (token, embedding_list) tuples."""
    with open(bin_path, 'rb') as f:
        data = f.read()

    num_tokens, vec_dim = struct.unpack_from('<ii', data, 0)
    offset = 8

    for _ in range(num_tokens):
        tok_len = struct.unpack_from('<I', data, offset)[0]
        offset += 4
        token = data[offset:offset + tok_len].decode('utf-8')
        offset += tok_len
        embedding = list(struct.unpack_from(f'<{vec_dim}f', data, offset))
        offset += vec_dim * 4
        yield token, embedding

    assert offset == len(data), f"Parse error: offset {offset} != file size {len(data)}"


def build_psql_env(cfg):
    """Return env dict and base psql args from config."""
    env = os.environ.copy()
    if cfg['password']:
        env['PGPASSWORD'] = cfg['password']
    psql = os.path.join(cfg['pgbin'], 'psql')
    base_args = [
        psql,
        '-h', cfg['host'],
        '-p', cfg['port'],
        '-U', cfg['user'],
        '-d', cfg['dbname'],
        '-v', 'ON_ERROR_STOP=1',
        '--no-psqlrc',
    ]
    return env, base_args


def run_sql(cfg, sql):
    """Execute a SQL string via psql."""
    env, args = build_psql_env(cfg)
    args += ['-c', sql]
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"SQL error:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def create_table(cfg):
    """Create the token_embeddings table (drop if exists)."""
    ddl = """
DROP TABLE IF EXISTS token_embeddings;
CREATE TABLE token_embeddings (
    id          SERIAL PRIMARY KEY,
    token       TEXT NOT NULL UNIQUE,
    embedding   REAL[] NOT NULL
);
"""
    print("Creating table token_embeddings...")
    run_sql(cfg, ddl)
    print("  Done.")


def load_embeddings(cfg, bin_path):
    """Insert all embeddings from the binary file into the table."""
    print(f"Parsing {bin_path}...")
    records = list(parse_embeddings(bin_path))
    print(f"  Found {len(records)} tokens.")

    # Build a single multi-row INSERT for efficiency
    BATCH_SIZE = 100
    total = 0
    for batch_start in range(0, len(records), BATCH_SIZE):
        batch = records[batch_start:batch_start + BATCH_SIZE]
        values_parts = []
        for token, emb in batch:
            # Escape single quotes in token
            safe_token = token.replace("'", "''")
            arr_literal = "ARRAY[" + ",".join(f"{v}" for v in emb) + "]::real[]"
            values_parts.append(f"('{safe_token}', {arr_literal})")

        sql = "INSERT INTO token_embeddings (token, embedding) VALUES\n" + \
              ",\n".join(values_parts) + ";"
        run_sql(cfg, sql)
        total += len(batch)
        print(f"  Inserted {total}/{len(records)} rows...")

    print(f"Load complete: {total} rows inserted.")


def verify(cfg):
    """Quick verification query."""
    out = run_sql(cfg, "SELECT count(*) AS total FROM token_embeddings;")
    print(f"Verification:\n{out}")
    out = run_sql(cfg, "SELECT id, token, embedding[1:3] AS first_3_dims FROM token_embeddings LIMIT 5;")
    print(out)


def main():
    if not os.path.exists(CONFIG_PATH):
        print(f"Config file not found: {CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)

    cfg = load_config()
    models_dir = os.path.normpath(os.path.join(SCRIPT_DIR, '..', cfg['models_dir']))
    bin_path = os.path.join(models_dir, 'sense_embeddings.bin')

    if not os.path.exists(bin_path):
        print(f"Embeddings file not found: {bin_path}", file=sys.stderr)
        sys.exit(1)

    create_table(cfg)
    load_embeddings(cfg, bin_path)
    verify(cfg)


if __name__ == '__main__':
    main()
