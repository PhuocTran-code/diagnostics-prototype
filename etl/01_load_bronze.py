# Bronze layer ETL: copy source tables into bronze as raw text
# Owner: E (Zeming Liu)
# TODO: implement


"""Load source tables into Bronze as full snapshots, preserving source values."""

from uuid import uuid4

import psycopg2
from psycopg2 import sql


# Each pair is (source schema, source table).
SOURCE_TABLES = [
    ("lis_a", "patient"),
    ("lis_a", "request"),
    ("lis_a", "result"),
    ("lis_b", "patients"),
    ("lis_b", "episodes"),
    ("lis_b", "observations"),
    ("ris", "patient"),
    ("ris", "exam_order"),
    ("ris", "report"),
]


def load_table(cur, source_schema, source_table, batch_id):
    """Copy one complete source table into its Bronze counterpart."""
    bronze_table = f"{source_schema}_{source_table}"
    source_ref = sql.Identifier(source_schema, source_table)
    bronze_ref = sql.Identifier("bronze", bronze_table)

    # Read the source column names in their original order.
    cur.execute(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
        ORDER BY ordinal_position
        """,
        (source_schema, source_table),
    )
    column_names = [row[0] for row in cur.fetchall()]
    if not column_names:
        raise RuntimeError(f"Source table not found: {source_schema}.{source_table}")

    columns = sql.SQL(", ").join(
        sql.Identifier(name) for name in column_names
    )

    # LIKE retains source column names and types. Metadata records provenance.
    cur.execute(
        sql.SQL("""
            CREATE TABLE IF NOT EXISTS {} (
                LIKE {},
                source_system VARCHAR(10) NOT NULL,
                batch_id UUID NOT NULL,
                ingested_at TIMESTAMPTZ NOT NULL
                    DEFAULT CURRENT_TIMESTAMP
            )
        """).format(bronze_ref, source_ref)
    )

    cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(source_ref))
    source_count = cur.fetchone()[0]

    # This prototype replaces the previous complete snapshot on each run.
    cur.execute(sql.SQL("TRUNCATE TABLE {}").format(bronze_ref))

    cur.execute(
        sql.SQL("""
            INSERT INTO {} ({}, source_system, batch_id)
            SELECT {}, %s, %s FROM {}
        """).format(bronze_ref, columns, columns, source_ref),
        (source_schema, batch_id),
    )
    loaded_count = cur.rowcount

    if loaded_count != source_count:
        raise RuntimeError(
            f"{source_schema}.{source_table}: "
            f"source={source_count}, loaded={loaded_count}"
        )

    return source_count, loaded_count


def main():
    batch_id = str(uuid4())
    results = []

    with psycopg2.connect(
        host="postgres",
        port=5432,
        dbname="lab",
        user="student",
        password="student",
    ) as conn:
        with conn.cursor() as cur:
            cur.execute("CREATE SCHEMA IF NOT EXISTS bronze")

            for source_schema, source_table in SOURCE_TABLES:
                source_count, loaded_count = load_table(
                    cur, source_schema, source_table, batch_id
                )
                results.append(
                    (source_schema, source_table, source_count, loaded_count)
                )

    # Printed after the database transaction has committed successfully.
    for source_schema, source_table, source_count, loaded_count in results:
        print(
            f"{source_schema}.{source_table}: "
            f"read {source_count}, loaded {loaded_count}"
        )


if __name__ == "__main__":
    main()
