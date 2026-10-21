"""Build the star schema (schema dw) from staging by running the SQL files in order.

Usage (from the project root, after src/ingest.py):
    python src/build_model.py
"""
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine, text

ROOT = Path(__file__).resolve().parents[1]
STEPS = sorted((ROOT / "sql" / "model").glob("*.sql")) + sorted((ROOT / "sql" / "kpis").glob("*.sql"))


def main():
    load_dotenv(ROOT / ".env")
    url = os.getenv("DATABASE_URL")
    if not url:
        sys.exit("DATABASE_URL is not set. Copy .env.example to .env and fill in your password.")
    engine = create_engine(url)
    with engine.begin() as con:   # one transaction: all or nothing
        for f in STEPS:
            print(f"running {f.relative_to(ROOT)}")
            con.exec_driver_sql(f.read_text(encoding="utf-8"))
        print()
        for t in ["dim_date", "dim_geography", "dim_customer", "dim_seller", "dim_product",
                  "fact_order_items", "fact_deliveries"]:
            n = con.execute(text(f"SELECT count(*) FROM dw.{t}")).scalar()
            print(f"  dw.{t}: {n:,} rows")


if __name__ == "__main__":
    main()
