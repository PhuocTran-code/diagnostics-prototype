"""
04: bronze -> silver (pandas)
Zeming's part, first draft by Junseog, Oct 2026

- read the bronze tables
- clean each source: dates -> timestamp, sex -> M/F/U, priority -> ROUTINE/URGENT,
  status -> IN_PROGRESS/FINAL/CANCELLED, local test codes -> LOINC via silver.test_code_map
- one row per source record, same columns for all three systems
- patient matching is NOT done here (05_resolve_identity.sql)
- one audit.pipeline_run row per table

writes silver.patient_source, diagnostic_request, pathology_result, imaging_report (DDL in 01)
full rebuild each run. run 03 first.
"""

from datetime import datetime

import pandas as pd
from sqlalchemy import Date, DateTime, Numeric

from db import get_engine, log_run, read_table, truncate, write_table

LOCAL_TZ = "Australia/Sydney"

STATUS_MAP = {
    "IP": "IN_PROGRESS", "IN_PROGRESS": "IN_PROGRESS", "SCHEDULED": "IN_PROGRESS",
    "FN": "FINAL", "FINAL": "FINAL", "COMPLETED": "FINAL",
    "CN": "CANCELLED", "CANCELLED": "CANCELLED",
}


# ---------- cleaning helpers, all the rules in one place ----------

def clean_text(s: pd.Series) -> pd.Series:
    """trim, collapse spaces, blank -> NA"""
    return s.astype("string").str.strip().str.replace(r"\s+", " ", regex=True).replace("", pd.NA)


def norm_name(s: pd.Series) -> pd.Series:
    return clean_text(s).str.upper()


def norm_medicare(s: pd.Series) -> pd.Series:
    """digits only, blank -> NA (blank must not match blank)"""
    return s.astype("string").fillna("").str.replace(r"[^0-9]", "", regex=True).replace("", pd.NA)


def norm_sex(s: pd.Series) -> pd.Series:
    first = s.astype("string").fillna("").str.strip().str.upper().str[:1]
    return first.where(first.isin(["M", "F"]), "U")


def norm_priority(s: pd.Series) -> pd.Series:
    first = s.astype("string").fillna("").str.strip().str.upper().str[:1]
    return first.map({"U": "URGENT"}).fillna("ROUTINE")


def norm_status(s: pd.Series) -> pd.Series:
    return s.astype("string").fillna("").str.strip().str.upper().map(STATUS_MAP).fillna("UNKNOWN")


def norm_abnormal(s: pd.Series) -> pd.Series:
    v = s.astype("string").fillna("").str.strip().str.upper()
    return v.where(v.isin(["L", "H"]), "N")


def to_local(utc: pd.Series) -> pd.Series:
    """timestamptz (UTC) -> naive local time, same as lis_a / ris"""
    return pd.to_datetime(utc, utc=True).dt.tz_convert(LOCAL_TZ).dt.tz_localize(None)


def drop_bronze_meta(df: pd.DataFrame) -> pd.DataFrame:
    return df.drop(columns=[c for c in ["source_system", "batch_id", "ingested_at"] if c in df.columns])


# ---------- 1. patient_source ----------

def build_patient_source(b: dict) -> pd.DataFrame:
    a = drop_bronze_meta(b["lis_a_patient"])
    lis_a = pd.DataFrame({
        "source_system": "lis_a",
        "source_patient_id": a["pat_no"].astype("string"),
        "medicare_no": norm_medicare(a["medicare_no"]),
        "family_name": norm_name(a["surname"]),
        "given_name": norm_name(a["given_names"]),
        "dob": pd.to_datetime(a["dob"].str.strip(), format="%d/%m/%Y", errors="coerce"),   # text date parsed once, here
        "sex_code": norm_sex(a["sex"]),
        "postcode": clean_text(a["postcode"]),
    })

    bb = drop_bronze_meta(b["lis_b_patients"])
    lis_b = pd.DataFrame({
        "source_system": "lis_b",
        "source_patient_id": bb["patient_guid"].astype("string"),
        "medicare_no": norm_medicare(bb["medicare_number"]),
        "family_name": norm_name(bb["family_name"]),
        "given_name": norm_name(bb["given_name"]),
        "dob": pd.to_datetime(bb["birth_date"]),
        "sex_code": norm_sex(bb["administrative_sex"]),      # male/female/unknown -> M/F/U
        "postcode": clean_text(bb["postcode"]),
    })

    r = drop_bronze_meta(b["ris_patient"])
    ris = pd.DataFrame({
        "source_system": "ris",
        "source_patient_id": r["ris_patient_id"].astype("string"),
        "medicare_no": norm_medicare(r["medicare_no"]),
        "family_name": norm_name(r["last_name"]),
        "given_name": norm_name(r["first_name"]),
        "dob": pd.to_datetime(r["date_of_birth"]),
        "sex_code": norm_sex(r["gender"]),
        "postcode": clean_text(r["postcode"]),
    })
    return pd.concat([lis_a, lis_b, ris], ignore_index=True)


# ---------- 2. diagnostic_request ----------

def build_requests(b: dict, keys: pd.DataFrame) -> pd.DataFrame:
    a = drop_bronze_meta(b["lis_a_request"])
    lis_a = pd.DataFrame({
        "request_id": a["req_no"],
        "source_patient_id": a["pat_no"].astype("string"),
        "referrer_code": clean_text(a["ref_doctor_code"]),
        "site_code": clean_text(a["site_code"]),
        "request_type": "PATHOLOGY",
        "collected_at": pd.to_datetime(a["coll_dt"], format="%d/%m/%Y %H:%M:%S", errors="coerce"),
        "priority": norm_priority(a["priority"]),
        "status": norm_status(a["status"]),
        "source_system": "lis_a",
    })

    e = drop_bronze_meta(b["lis_b_episodes"])
    lis_b = pd.DataFrame({
        "request_id": e["accession_number"],
        "source_patient_id": e["patient_guid"].astype("string"),
        "referrer_code": clean_text(e["ordering_provider"]),
        "site_code": clean_text(e["site_code"]),
        "request_type": "PATHOLOGY",
        "collected_at": to_local(e["collected_utc"]),
        "priority": norm_priority(e["urgency"]),
        "status": norm_status(e["episode_status"]),
        "source_system": "lis_b",
    })

    o = drop_bronze_meta(b["ris_exam_order"])
    ris = pd.DataFrame({
        "request_id": o["accession_number"],
        "source_patient_id": o["ris_patient_id"].astype("string"),
        "referrer_code": clean_text(o["referrer_code"]),
        "site_code": clean_text(o["site_code"]),
        "request_type": "IMAGING",
        "collected_at": pd.to_datetime(o["order_datetime"]),
        "priority": norm_priority(o["priority"]),
        "status": norm_status(o["order_status"]),
        "source_system": "ris",
    })

    req = pd.concat([lis_a, lis_b, ris], ignore_index=True)
    # look up the silver patient key (source_system + source id -> patient_source_key)
    req = req.merge(keys, on=["source_system", "source_patient_id"], how="inner", validate="many_to_one")
    cols = ["request_id", "patient_source_key", "referrer_code", "site_code", "request_type",
            "collected_at", "priority", "status", "source_system"]
    return req[cols]


# ---------- 3. pathology_result ----------

def build_pathology_results(b: dict, code_map: pd.DataFrame) -> pd.DataFrame:
    map_a = code_map[code_map["source_system"] == "lis_a"][["source_code", "loinc_code", "test_name"]]
    map_b = code_map[code_map["source_system"] == "lis_b"][["source_code", "loinc_code", "test_name"]]

    a = drop_bronze_meta(b["lis_a_result"]).merge(map_a, left_on="test_code", right_on="source_code", how="left",
                                                   suffixes=("", "_map"))
    lis_a = pd.DataFrame({
        "result_id": a["result_id"].astype("int64"),
        "request_id": a["req_no"],
        "loinc_code": a["loinc_code"],
        "test_name": a["test_name_map"].fillna(a["test_name"]),
        "result_value": pd.to_numeric(a["result_value"].astype("string").str.strip(), errors="coerce"),   # 'POS' -> NULL, not a crash
        "unit": clean_text(a["unit"]),
        "abnormal_flag": norm_abnormal(a["abn_flag"]),
        "verified_at": pd.to_datetime(a["verified_dt"], format="%d/%m/%Y %H:%M:%S", errors="coerce"),
    })

    ob = drop_bronze_meta(b["lis_b_observations"])
    ep = drop_bronze_meta(b["lis_b_episodes"])[["episode_id", "accession_number"]]
    o = ob.merge(ep, on="episode_id", how="inner").merge(map_b, left_on="loinc_code", right_on="source_code",
                                                         how="left", suffixes=("", "_map"))
    lis_b = pd.DataFrame({
        "result_id": 1_000_000_000 + o["observation_id"].astype("int64"),   # keep lis_b ids out of lis_a's range
        "request_id": o["accession_number"],
        "loinc_code": o["loinc_code_map"].fillna(o["loinc_code"]),
        "test_name": o["test_name"].fillna(o["analyte_name"]),
        "result_value": o["value_numeric"],
        "unit": clean_text(o["ucum_unit"]),
        "abnormal_flag": norm_abnormal(o["interpretation"]),
        "verified_at": to_local(o["reported_utc"]),
    })
    return pd.concat([lis_a, lis_b], ignore_index=True)


# ---------- 4. imaging_report ----------

def build_imaging_reports(b: dict) -> pd.DataFrame:
    rp = drop_bronze_meta(b["ris_report"])
    o = drop_bronze_meta(b["ris_exam_order"])[["accession_number", "procedure_code", "modality"]]
    df = rp.merge(o, on="accession_number", how="inner")
    df = df.sort_values(["accession_number", "verified_at"], ascending=[True, False])
    df = df.drop_duplicates("accession_number", keep="first")     # latest report per accession
    return pd.DataFrame({
        "accession_number": df["accession_number"],
        "procedure_code": df["procedure_code"],
        "modality": df["modality"],
        "performed_at": pd.to_datetime(df["performed_at"]),
        "verified_at": pd.to_datetime(df["verified_at"]),
        "report_status": df["report_status"].astype("string").str.upper(),
        "critical_finding": df["critical_finding"].fillna(False).astype(bool),
    })


# ---------- main ----------

def main():
    engine = get_engine()
    started = datetime.now()

    bronze_tables = ["lis_a_patient", "lis_a_request", "lis_a_result",
                     "lis_b_patients", "lis_b_episodes", "lis_b_observations",
                     "ris_patient", "ris_exam_order", "ris_report"]
    b = {t: read_table(engine, "bronze", t) for t in bronze_tables}
    code_map = read_table(engine, "silver", "test_code_map")

    truncate(engine, ["silver.pathology_result", "silver.imaging_report", "silver.diagnostic_request",
                      "silver.patient_xref", "silver.patient", "silver.patient_source"])

    # 1. patients (keys are generated by the table, read them back for the joins)
    ps = build_patient_source(b)
    n_ps = write_table(engine, ps, "silver", "patient_source", dtype={"dob": Date()})
    keys = read_table(engine, "silver", "patient_source")[["patient_source_key", "source_system", "source_patient_id"]]
    keys["source_patient_id"] = keys["source_patient_id"].astype("string")
    log_run(engine, "silver", "bronze", "silver.patient_source",
            sum(len(b[t]) for t in ["lis_a_patient", "lis_b_patients", "ris_patient"]), n_ps, started)
    print(f"silver.patient_source: {n_ps}")

    # 2. requests
    req = build_requests(b, keys)
    n_req = write_table(engine, req, "silver", "diagnostic_request", dtype={"collected_at": DateTime()})
    log_run(engine, "silver", "bronze", "silver.diagnostic_request",
            sum(len(b[t]) for t in ["lis_a_request", "lis_b_episodes", "ris_exam_order"]), n_req, started)
    print(f"silver.diagnostic_request: {n_req}")

    # 3. pathology results
    res = build_pathology_results(b, code_map)
    n_res = write_table(engine, res, "silver", "pathology_result",
                        dtype={"result_value": Numeric(12, 4), "verified_at": DateTime()})
    log_run(engine, "silver", "bronze", "silver.pathology_result",
            len(b["lis_a_result"]) + len(b["lis_b_observations"]), n_res, started)
    print(f"silver.pathology_result: {n_res}")

    # 4. imaging reports
    img = build_imaging_reports(b)
    n_img = write_table(engine, img, "silver", "imaging_report",
                        dtype={"performed_at": DateTime(), "verified_at": DateTime()})
    log_run(engine, "silver", "bronze", "silver.imaging_report", len(b["ris_report"]), n_img, started)
    print(f"silver.imaging_report: {n_img}")


if __name__ == "__main__":
    main()
