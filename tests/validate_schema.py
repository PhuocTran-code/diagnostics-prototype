"""
3.5c schema validation: gold matches the design and FKs hold
Junseog, Oct 2026

same helpers as the workshop 07_validate_warehouse.py (unique, not null,
non negative, fk values exist) plus two structure checks against information_schema.
run after 07_load_gold.py.
"""

import os
import sys

import pandas as pd
from sqlalchemy import text

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pipeline"))
from db import get_engine, read_table  # noqa: E402

GOLD_TABLES = ["dim_patient", "dim_date", "dim_site", "dim_referrer", "dim_test", "dim_procedure",
               "fact_pathology_result", "fact_imaging_study"]


# ---------- structure (does gold match Figure 2) ----------

def assert_tables_exist(engine, schema, tables):
    with engine.connect() as conn:
        found = conn.execute(
            text("SELECT table_name FROM information_schema.tables WHERE table_schema = :s"),
            {"s": schema},
        ).scalars().all()
    missing = [t for t in tables if t not in found]
    if missing:
        raise AssertionError(f"{schema} is missing tables: {missing}")
    print(f"[PASS] {schema} has all {len(tables)} tables from the design")


def assert_foreign_keys_declared(engine, schema, table, expected):
    with engine.connect() as conn:
        n = conn.execute(
            text("""
                SELECT COUNT(*) FROM information_schema.table_constraints
                WHERE table_schema = :s AND table_name = :t AND constraint_type = 'FOREIGN KEY'
            """),
            {"s": schema, "t": table},
        ).scalar()
    if n != expected:
        raise AssertionError(f"{schema}.{table} has {n} foreign keys, expected {expected}")
    print(f"[PASS] {schema}.{table} declares {expected} foreign keys")


# ---------- integrity (workshop helpers) ----------

def assert_unique(dataframe, key_columns, table_name):
    duplicate_count = dataframe.duplicated(subset=key_columns).sum()
    if duplicate_count > 0:
        raise AssertionError(f"{table_name} contains {duplicate_count:,} duplicate keys for {key_columns}")
    print(f"[PASS] {table_name} unique key: {key_columns}")


def assert_not_null(dataframe, columns, table_name):
    invalid_count = dataframe[columns].isna().any(axis=1).sum()
    if invalid_count > 0:
        raise AssertionError(f"{table_name} contains {invalid_count:,} rows with missing required values")
    print(f"[PASS] {table_name} required columns contain no nulls")


def assert_non_negative(dataframe, columns, table_name):
    for column in columns:
        invalid_count = (dataframe[column] < 0).sum()
        if invalid_count > 0:
            raise AssertionError(f"{table_name}.{column} contains {invalid_count:,} negative values")
    print(f"[PASS] {table_name} contains no negative values in {columns}")


def assert_foreign_key_values_exist(fact, dimension, fact_key, dimension_key, relationship_name):
    missing_keys = (~fact[fact_key].isin(dimension[dimension_key])).sum()
    if missing_keys > 0:
        raise AssertionError(f"{relationship_name} has {missing_keys:,} unmatched keys")
    print(f"[PASS] {relationship_name}")


def main():
    engine = get_engine()

    # structure
    assert_tables_exist(engine, "gold", GOLD_TABLES)
    assert_foreign_keys_declared(engine, "gold", "fact_pathology_result", 5)
    assert_foreign_keys_declared(engine, "gold", "fact_imaging_study", 5)

    g = {t: read_table(engine, "gold", t) for t in GOLD_TABLES}
    fact_path = g["fact_pathology_result"]
    fact_img = g["fact_imaging_study"]

    # unique keys
    assert_unique(g["dim_patient"], ["patient_key"], "gold.dim_patient")
    assert_unique(g["dim_date"], ["date_key"], "gold.dim_date")
    assert_unique(g["dim_site"], ["site_key"], "gold.dim_site")
    assert_unique(g["dim_referrer"], ["referrer_key"], "gold.dim_referrer")
    assert_unique(g["dim_test"], ["test_key"], "gold.dim_test")
    assert_unique(g["dim_procedure"], ["procedure_key"], "gold.dim_procedure")
    assert_unique(fact_path, ["result_id"], "gold.fact_pathology_result")
    assert_unique(fact_img, ["accession_number"], "gold.fact_imaging_study")

    # required keys present
    assert_not_null(fact_path, ["patient_key", "date_key", "site_key", "referrer_key", "test_key"],
                    "gold.fact_pathology_result")
    assert_not_null(fact_img, ["patient_key", "date_key", "site_key", "referrer_key", "procedure_key"],
                    "gold.fact_imaging_study")

    # turnaround can't be negative
    assert_non_negative(fact_path, ["turnaround_minutes"], "gold.fact_pathology_result")
    assert_non_negative(fact_img, ["turnaround_hours"], "gold.fact_imaging_study")

    # every fact key exists in its dimension
    for fk, dim, dk in [("patient_key", "dim_patient", "patient_key"),
                        ("date_key", "dim_date", "date_key"),
                        ("site_key", "dim_site", "site_key"),
                        ("referrer_key", "dim_referrer", "referrer_key"),
                        ("test_key", "dim_test", "test_key")]:
        assert_foreign_key_values_exist(fact_path, g[dim], fk, dk, f"fact_pathology_result to {dim}")
    for fk, dim, dk in [("patient_key", "dim_patient", "patient_key"),
                        ("date_key", "dim_date", "date_key"),
                        ("site_key", "dim_site", "site_key"),
                        ("referrer_key", "dim_referrer", "referrer_key"),
                        ("procedure_key", "dim_procedure", "procedure_key")]:
        assert_foreign_key_values_exist(fact_img, g[dim], fk, dk, f"fact_imaging_study to {dim}")

    print()
    print("All schema validation tests passed.")


if __name__ == "__main__":
    main()
