#!/usr/bin/env bash
# Rebuild everything: download SynPUF sample 2 -> load + query in DuckDB -> figures.
set -euo pipefail
cd "$(dirname "$0")"
uv sync
uv run python src/01_fetch_data.py
rm -f data/synpuf.duckdb   # always rebuild the database from the raw CSVs
uv run python src/02_run_sql.py
uv run python src/03_figures.py
