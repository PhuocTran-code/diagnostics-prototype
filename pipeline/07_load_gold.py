"""
07: silver -> gold star schema (pandas)
Junseog, Oct 2026

reads silver.patient / patient_xref / diagnostic_request / pathology_result / imaging_report / test_code_map
writes the 8 gold tables from 06_gold_schema.sql

notes
- patients keyed on the golden id, so lis_a + lis_b + ris rows for one person -> one dim_patient row
- dims (except patient) get an UNKNOWN row with key 0, facts with unmapped codes point there instead of NULL
- turnaround precomputed (minutes for pathology, hours for imaging)
- no names / dob / medicare in gold

full rebuild each run. run 04, 05, 06 first.
"""

from datetime import datetime

import pandas as pd

from db import get_engine, log_run, read_table, truncate, write_table


def create_dimension(df: pd.DataFrame, business_key: str, surrogate_key: str,
                     unknown_row: dict | None = None) -> pd.DataFrame:
    """same as the workshop helper: dedupe on business key, add 1..n surrogate key. plus optional UNKNOWN row (key 0)"""
    dim = df.drop_duplicates(subset=[business_key]).sort_values(business_key).reset_index(drop=True).copy()
    dim.insert(0, surrogate_key, range(1, len(dim) + 1))
    if unknown_row is not None:
        dim = pd.concat([pd.DataFrame([{surrogate_key: 0, **unknown_row}]), dim], ignore_index=True)
    return dim


# ---------- dimensions ----------

def build_dim_date(start="2025-01-01", end="2027-12-31") -> pd.DataFrame:
    d = pd.date_range(start, end, freq="D")
    return pd.DataFrame({
        "date_key": d.strftime("%Y%m%d").astype(int),
        "full_date": d.date,
        "year_number": d.year,
        "quarter_number": d.quarter,
        "month_number": d.month,
        "month_name": d.strftime("%B"),
        "day_of_week": d.dayofweek + 1,          # 1 = Monday .. 7 = Sunday
        "day_name": d.strftime("%A"),
        "is_weekend": d.dayofweek >= 5,
    })


def build_dim_site(req: pd.DataFrame) -> pd.DataFrame:
    sites = req[["site_code"]].dropna().drop_duplicates()
    sites["site_name"] = "Collection centre " + sites["site_code"]      # no site master in the sources, synthetic
    sites["state"] = "NSW"
    return create_dimension(sites, "site_code", "site_key",
                            {"site_code": "UNKNOWN", "site_name": "Unknown site", "state": None})


def build_dim_referrer(req: pd.DataFrame) -> pd.DataFrame:
    ref = req[["referrer_code"]].dropna().drop_duplicates().rename(columns={"referrer_code": "provider_number"})
    ref["specialty"] = "General practice"                               # synthetic default
    return create_dimension(ref, "provider_number", "referrer_key",
                            {"provider_number": "UNKNOWN", "specialty": "Unknown"})


def build_dim_test(code_map: pd.DataFrame, res: pd.DataFrame) -> pd.DataFrame:
    # names: terminology map wins over whatever text the source carried
    from_map = code_map[code_map["loinc_code"].notna()][["loinc_code", "test_name"]].assign(rank=1)
    from_res = res[res["loinc_code"].notna()][["loinc_code", "test_name"]].assign(rank=2)
    names = (pd.concat([from_map, from_res]).sort_values(["loinc_code", "rank"])
             .drop_duplicates("loinc_code")[["loinc_code", "test_name"]])
    # unit: the one seen most often for that test
    units = (res.dropna(subset=["loinc_code", "unit"])
             .groupby(["loinc_code", "unit"]).size().reset_index(name="n")
             .sort_values(["loinc_code", "n"], ascending=[True, False])
             .drop_duplicates("loinc_code")[["loinc_code", "unit"]])
    tests = names.merge(units, on="loinc_code", how="left")
    return create_dimension(tests, "loinc_code", "test_key",
                            {"loinc_code": "UNKNOWN", "test_name": "Unmapped local test code", "unit": None})


def build_dim_procedure(code_map: pd.DataFrame, img: pd.DataFrame) -> pd.DataFrame:
    from_map = (code_map[code_map["modality"].notna()]
                .rename(columns={"source_code": "procedure_code", "test_name": "procedure_name"})
                [["procedure_code", "procedure_name", "modality"]].assign(rank=1))
    from_img = img[["procedure_code", "modality"]].drop_duplicates().assign(procedure_name=lambda d: d["procedure_code"], rank=2)
    procs = (pd.concat([from_map, from_img]).sort_values(["procedure_code", "rank"])
             .drop_duplicates("procedure_code")[["procedure_code", "procedure_name", "modality"]])
    return create_dimension(procs, "procedure_code", "procedure_key",
                            {"procedure_code": "UNKNOWN", "procedure_name": "Unmapped procedure", "modality": None})


def build_dim_patient(patient: pd.DataFrame, xref: pd.DataFrame, ps: pd.DataFrame) -> pd.DataFrame:
    cur = patient[patient["is_current"]].copy()
    systems = (xref.merge(ps[["patient_source_key", "source_system"]], on="patient_source_key")
               .groupby("patient_key")["source_system"].nunique().rename("source_system_count"))
    cur = cur.merge(systems, left_on="patient_key", right_index=True, how="left")
    dim = pd.DataFrame({
        "patient_id": cur["golden_id"].astype(str),
        "sex_code": cur["sex_code"],
        "birth_year": pd.to_datetime(cur["dob"]).dt.year.astype("Int64"),
        "postcode": cur["postcode"],
        "source_system_count": cur["source_system_count"].fillna(1).astype(int),
        "silver_patient_key": cur["patient_key"],          # helper for the fact joins, not written
    })
    dim = dim.sort_values("silver_patient_key").reset_index(drop=True)
    dim.insert(0, "patient_key", range(1, len(dim) + 1))
    return dim


# ---------- facts ----------

def patient_key_lookup(xref: pd.DataFrame, dim_patient: pd.DataFrame) -> pd.DataFrame:
    """patient_source_key -> gold patient_key (via the crosswalk)"""
    return (xref[["patient_source_key", "patient_key"]].rename(columns={"patient_key": "silver_patient_key"})
            .merge(dim_patient[["silver_patient_key", "patient_key"]], on="silver_patient_key")
            [["patient_source_key", "patient_key"]])


def build_fact_pathology(res, req, pk, dim_site, dim_ref, dim_test) -> pd.DataFrame:
    f = (res.merge(req, on="request_id", how="inner", suffixes=("", "_req"))
            .merge(pk, on="patient_source_key", how="inner")
            .merge(dim_site[["site_code", "site_key"]], on="site_code", how="left")
            .merge(dim_ref[["provider_number", "referrer_key"]], left_on="referrer_code", right_on="provider_number", how="left")
            .merge(dim_test[["loinc_code", "test_key"]], on="loinc_code", how="left"))
    tat = (pd.to_datetime(f["verified_at"]) - pd.to_datetime(f["collected_at"])).dt.total_seconds() / 60
    return pd.DataFrame({
        "result_id": f["result_id"].astype("int64"),
        "request_id": f["request_id"],
        "patient_key": f["patient_key"].astype(int),
        "date_key": pd.to_datetime(f["collected_at"]).dt.strftime("%Y%m%d").astype(int),
        "site_key": f["site_key"].fillna(0).astype(int),
        "referrer_key": f["referrer_key"].fillna(0).astype(int),
        "test_key": f["test_key"].fillna(0).astype(int),
        "source_system": f["source_system"],
        "priority": f["priority"],
        "result_value": f["result_value"],
        "unit": f["unit"],
        "abnormal_flag": f["abnormal_flag"],
        "is_abnormal": f["abnormal_flag"].isin(["L", "H"]),
        "turnaround_minutes": tat.round().astype("Int64"),
    })


def build_fact_imaging(img, req, pk, dim_site, dim_ref, dim_proc) -> pd.DataFrame:
    f = (img.merge(req, left_on="accession_number", right_on="request_id", how="inner", suffixes=("", "_req"))
            .merge(pk, on="patient_source_key", how="inner")
            .merge(dim_site[["site_code", "site_key"]], on="site_code", how="left")
            .merge(dim_ref[["provider_number", "referrer_key"]], left_on="referrer_code", right_on="provider_number", how="left")
            .merge(dim_proc[["procedure_code", "procedure_key"]], on="procedure_code", how="left"))
    tat = (pd.to_datetime(f["verified_at"]) - pd.to_datetime(f["collected_at"])).dt.total_seconds() / 3600
    return pd.DataFrame({
        "accession_number": f["accession_number"],
        "patient_key": f["patient_key"].astype(int),
        "date_key": pd.to_datetime(f["collected_at"]).dt.strftime("%Y%m%d").astype(int),
        "site_key": f["site_key"].fillna(0).astype(int),
        "referrer_key": f["referrer_key"].fillna(0).astype(int),
        "procedure_key": f["procedure_key"].fillna(0).astype(int),
        "source_system": f["source_system"],
        "priority": f["priority"],
        "report_status": f["report_status"],
        "critical_finding": f["critical_finding"].astype(bool),
        "turnaround_hours": tat.round().astype("Int64"),
    })


# ---------- main ----------

def main():
    engine = get_engine()
    started = datetime.now()

    patient = read_table(engine, "silver", "patient")
    xref = read_table(engine, "silver", "patient_xref")
    ps = read_table(engine, "silver", "patient_source")
    req = read_table(engine, "silver", "diagnostic_request")
    res = read_table(engine, "silver", "pathology_result")
    img = read_table(engine, "silver", "imaging_report")
    code_map = read_table(engine, "silver", "test_code_map")

    truncate(engine, ["gold.fact_pathology_result", "gold.fact_imaging_study", "gold.dim_patient",
                      "gold.dim_date", "gold.dim_site", "gold.dim_referrer", "gold.dim_test", "gold.dim_procedure"])

    dim_date = build_dim_date()
    dim_site = build_dim_site(req)
    dim_ref = build_dim_referrer(req)
    dim_test = build_dim_test(code_map, res)
    dim_proc = build_dim_procedure(code_map, img)
    dim_patient = build_dim_patient(patient, xref, ps)

    write_table(engine, dim_date, "gold", "dim_date")
    write_table(engine, dim_site, "gold", "dim_site")
    write_table(engine, dim_ref, "gold", "dim_referrer")
    write_table(engine, dim_test, "gold", "dim_test")
    write_table(engine, dim_proc, "gold", "dim_procedure")
    n_pat = write_table(engine, dim_patient.drop(columns=["silver_patient_key"]), "gold", "dim_patient")
    for name, d in [("dim_date", dim_date), ("dim_site", dim_site), ("dim_referrer", dim_ref),
                    ("dim_test", dim_test), ("dim_procedure", dim_proc), ("dim_patient", dim_patient)]:
        print(f"gold.{name}: {len(d)}")

    pk = patient_key_lookup(xref, dim_patient)
    fact_path = build_fact_pathology(res, req, pk, dim_site, dim_ref, dim_test)
    fact_img = build_fact_imaging(img, req, pk, dim_site, dim_ref, dim_proc)
    n_path = write_table(engine, fact_path, "gold", "fact_pathology_result")
    n_img = write_table(engine, fact_img, "gold", "fact_imaging_study")
    print(f"gold.fact_pathology_result: {n_path}")
    print(f"gold.fact_imaging_study: {n_img}")

    log_run(engine, "gold", "silver", "gold.dim_patient", int(patient["is_current"].sum()), n_pat, started)
    log_run(engine, "gold", "silver", "gold.fact_pathology_result", len(res), n_path, started)
    log_run(engine, "gold", "silver", "gold.fact_imaging_study", len(img), n_img, started)


if __name__ == "__main__":
    main()
