"""Run sql/*.sql in order against data/synpuf.duckdb and export every table
named out_* to outputs/tables/<name>.csv.

Usage:  uv run python src/02_run_sql.py             (all files)
        uv run python src/02_run_sql.py 01_pmpy     (one file; needs 00_load done once)
"""

import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
RAW, SQL, TAB = ROOT / "data" / "raw", ROOT / "sql", ROOT / "outputs" / "tables"
DB = ROOT / "data" / "synpuf.duckdb"


def main(only=None):
    TAB.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB))
    files = sorted(SQL.glob("*.sql"))
    if only:
        files = [f for f in files if f.stem in only]
    for f in files:
        t = time.time()
        con.execute(f.read_text().replace("{RAW}", RAW.as_posix()))
        print(f"{f.name}: {time.time() - t:.1f}s", flush=True)

    for (name,) in con.execute(
        "SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'out_%' ORDER BY 1"
    ).fetchall():
        df = con.table(name).df()
        df.to_csv(TAB / f"{name.removeprefix('out_')}.csv", index=False)
        print(f"\n== {name} ({len(df)} rows)")
        print(df.head(12).to_string(index=False))
    con.close()


if __name__ == "__main__":
    main(sys.argv[1:] or None)
