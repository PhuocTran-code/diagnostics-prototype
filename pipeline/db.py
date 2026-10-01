"""db helpers shared by the python steps (like database.py in the workshop)"""

import os
from datetime import datetime

import pandas as pd
from sqlalchemy import create_engine, text


def database_url() -> str:
    host = os.environ.get("PGHOST", "postgres")
    port = os.environ.get("PGPORT", "5432")
    db = os.environ.get("PGDATABASE", "medscan")
    user = os.environ.get("PGUSER", "student")
    pw = os.environ.get("PGPASSWORD", "student")
    return f"postgresql+psycopg2://{user}:{pw}@{host}:{port}/{db}"


def get_engine():
    return create_engine(database_url(), future=True)


def read_table(engine, schema: str, table: str) -> pd.DataFrame:
    return pd.read_sql_table(table, con=engine, schema=schema)


def truncate(engine, tables: list[str]) -> None:
    with engine.begin() as conn:
        conn.execute(text(f"TRUNCATE TABLE {', '.join(tables)} RESTART IDENTITY CASCADE"))


def write_table(engine, df: pd.DataFrame, schema: str, table: str, dtype=None) -> int:
    """Append a DataFrame into an existing table. pd.NA / NaN become NULL."""
    out = df.copy()
    for col in out.columns:
        if out[col].dtype == object or str(out[col].dtype) == "string":
            out[col] = out[col].astype(object).where(out[col].notna(), None)
    out.to_sql(table, con=engine, schema=schema, if_exists="append", index=False,
               method="multi", chunksize=500, dtype=dtype)
    return len(out)


def log_run(engine, layer: str, source: str, target: str, rows_read: int, rows_loaded: int,
            started: datetime, status: str = "SUCCESS") -> None:
    with engine.begin() as conn:
        conn.execute(
            text("""
                INSERT INTO audit.pipeline_run
                    (layer, source_name, target_table, rows_read, rows_loaded, run_status, started_at, completed_at)
                VALUES (:layer, :source, :target, :read, :loaded, :status, :started, NOW())
            """),
            dict(layer=layer, source=source, target=target, read=int(rows_read),
                 loaded=int(rows_loaded), status=status, started=started),
        )
