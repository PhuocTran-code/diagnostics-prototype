"""
Runs the whole prototype in order and prints the validation results.

Run it inside the python container so it can reach postgres by service name:

    docker compose run --rm python python run_pipeline.py

Env vars (all optional): PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD.
Default database is medscan. It is created if it does not exist.
"""

import os
import runpy
import sys
import time

import psycopg2

STEPS = [
    "pipeline/01_source_schemas.sql",
    "pipeline/02_synthetic_data.sql",
    "pipeline/03_load_bronze.py",
    "pipeline/04_build_silver.py",
    "pipeline/05_resolve_identity.sql",
    "pipeline/06_gold_schema.sql",
    "pipeline/07_load_gold.py",
    "pipeline/08_dashboard_views.sql",
]

TESTS = [
    "tests/validate_data_layer.sql",
    "tests/validate_mpi.sql",
    "tests/validate_schema.py",
]

CONN = dict(
    host=os.environ.get("PGHOST", "postgres"),
    port=int(os.environ.get("PGPORT", "5432")),
    user=os.environ.get("PGUSER", "student"),
    password=os.environ.get("PGPASSWORD", "student"),
)
DBNAME = os.environ.get("PGDATABASE", "medscan")

ROOT = os.path.dirname(os.path.abspath(__file__))


def wait_for_postgres(attempts=15):
    for i in range(attempts):
        try:
            psycopg2.connect(dbname="postgres", **CONN).close()
            return
        except psycopg2.OperationalError:
            print(f"waiting for postgres ({i + 1}/{attempts})")
            time.sleep(2)
    sys.exit("postgres not reachable")


def ensure_database():
    conn = psycopg2.connect(dbname="postgres", **CONN)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (DBNAME,))
        if cur.fetchone() is None:
            cur.execute(f'CREATE DATABASE "{DBNAME}" OWNER {CONN["user"]}')
            print(f"created database {DBNAME}")
    conn.close()


def print_rows(cur):
    """Print the last result set of a script as a simple table."""
    if cur.description is None:
        return
    rows = cur.fetchall()
    names = [d[0] for d in cur.description]
    widths = [max(len(str(n)), *(len(str(r[i])) for r in rows)) if rows else len(str(n))
              for i, n in enumerate(names)]
    line = " | ".join(str(n).ljust(w) for n, w in zip(names, widths))
    print(line)
    print("-" * len(line))
    for r in rows:
        print(" | ".join(str(v).ljust(w) for v, w in zip(r, widths)))
    print(f"({len(rows)} rows)")


def run_sql(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        sql = f.read()
    code = "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--"))
    if not code.strip():
        print("(no statements yet, skipped)")
        return
    conn = psycopg2.connect(dbname=DBNAME, **CONN)
    conn.autocommit = True        # scripts manage their own BEGIN/COMMIT
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            print_rows(cur)
    finally:
        conn.close()


def run_py(path):
    os.environ.setdefault("PGDATABASE", DBNAME)
    sys.path.insert(0, os.path.join(ROOT, "pipeline"))   # so steps can import db.py
    runpy.run_path(os.path.join(ROOT, path), run_name="__main__")


def run(path):
    print(f"\n----- {path}")
    try:
        if path.endswith(".py"):
            run_py(path)
        else:
            run_sql(path)
    except Exception as exc:          # stop at the first broken step
        print(f"!!! FAILED: {path}\n{exc}")
        sys.exit(1)


def main():
    print(f"=== diagnostics prototype, database={DBNAME} host={CONN['host']}")
    wait_for_postgres()
    ensure_database()
    for step in STEPS:
        run(step)
    print("\n=== validation")
    for test in TESTS:
        run(test)
    print("\n=== done")


if __name__ == "__main__":
    main()
