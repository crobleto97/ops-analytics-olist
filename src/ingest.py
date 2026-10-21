"""Load the Olist CSV files, run data-quality checks and write them to PostgreSQL.

Usage (from the project root):
    python src/ingest.py

Result in the database:
    staging.<table>        clean rows, one table per CSV
    dq.check_results       one row per check and run: how many rows failed
    dq.rejected_rows       the rows removed from staging and why
"""
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

sys.path.insert(0, str(Path(__file__).parent))
from schema import LOAD_ORDER, RULES, TABLES  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"


class Run:
    """Collects check results and rejected rows for one execution."""

    def __init__(self):
        self.id = uuid.uuid4().hex[:8]
        self.started = datetime.now(timezone.utc)
        self.results = []
        self.rejected = []

    def log(self, table, check, df_bad, severity, key_cols):
        n = len(df_bad)
        self.results.append(dict(run_id=self.id, run_at=self.started, table_name=table,
                                 check_name=check, severity=severity, failed_rows=n))
        if n and severity == "reject":
            keys = df_bad[key_cols].astype(str).agg("|".join, axis=1) if key_cols else df_bad.index.astype(str)
            self.rejected += [dict(run_id=self.id, table_name=table, check_name=check, row_key=k)
                              for k in keys]
        flag = "OK " if n == 0 else ("REJ" if severity == "reject" else "WRN")
        print(f"  [{flag}] {check}: {n}")


def read_csv(name: str, spec: dict) -> pd.DataFrame:
    path = RAW / spec["file"]
    if not path.exists():
        raise FileNotFoundError(f"Missing {path}. Unzip the Kaggle download into data/raw/.")
    df = pd.read_csv(path, dtype=str, encoding="utf-8-sig")  # utf-8-sig drops the BOM some files carry

    missing = set(spec["columns"]) - set(df.columns)
    extra = set(df.columns) - set(spec["columns"])
    if missing:
        raise ValueError(f"{spec['file']}: missing columns {sorted(missing)}")
    if extra:
        print(f"  note: extra columns ignored: {sorted(extra)}")
    df = df[list(spec["columns"])]

    for col, kind in spec["columns"].items():
        if kind == "str":
            df[col] = df[col].str.strip()
        elif kind == "int":
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("Int64")
        elif kind == "float":
            df[col] = pd.to_numeric(df[col], errors="coerce")
        elif kind == "datetime":
            df[col] = pd.to_datetime(df[col], errors="coerce")
    return df


def check_table(name: str, df: pd.DataFrame, loaded: dict, run: Run) -> pd.DataFrame:
    spec = TABLES[name]
    pk = spec["pk"]
    bad = pd.Series(False, index=df.index)

    if pk:
        null_key = df[pk].isna().any(axis=1)
        run.log(name, f"null primary key ({', '.join(pk)})", df[null_key], "reject", pk)
        dup = df.duplicated(subset=pk, keep="first") & ~null_key
        run.log(name, f"duplicate primary key ({', '.join(pk)})", df[dup], "reject", pk)
        bad |= null_key | dup

    for col, (parent, pcol) in spec["fk"].items():
        orphan = df[col].notna() & ~df[col].isin(loaded[parent][pcol])
        run.log(name, f"{col} not found in {parent}", df[orphan], "reject", pk)
        bad |= orphan

    for table, desc, rule, severity in RULES:
        if table != name:
            continue
        mask = rule(df).fillna(False).astype(bool)
        run.log(name, desc, df[mask], severity, pk)
        if severity == "reject":
            bad |= mask

    return df[~bad].copy()


def main():
    load_dotenv(ROOT / ".env")
    url = os.getenv("DATABASE_URL")
    if not url:
        sys.exit("DATABASE_URL is not set. Copy .env.example to .env and fill in your password.")
    engine = create_engine(url)
    run = Run()
    loaded = {}

    with engine.begin() as con:
        con.execute(text("CREATE SCHEMA IF NOT EXISTS staging"))
        con.execute(text("CREATE SCHEMA IF NOT EXISTS dq"))

    for name in LOAD_ORDER:
        print(f"\n{name}")
        df = read_csv(name, TABLES[name])
        clean = check_table(name, df, loaded, run)
        loaded[name] = clean
        clean.to_sql(name, engine, schema="staging", if_exists="replace", index=False,
                     chunksize=20_000, method="multi")
        print(f"  -> staging.{name}: {len(clean):,} of {len(df):,} rows")

    pd.DataFrame(run.results).to_sql("check_results", engine, schema="dq",
                                     if_exists="append", index=False)
    if run.rejected:
        pd.DataFrame(run.rejected).to_sql("rejected_rows", engine, schema="dq",
                                          if_exists="append", index=False)

    rejected = sum(r["failed_rows"] for r in run.results if r["severity"] == "reject")
    warned = sum(r["failed_rows"] for r in run.results if r["severity"] == "warn")
    print(f"\nRun {run.id} finished: {rejected:,} rows rejected, {warned:,} warnings.")


if __name__ == "__main__":
    main()
