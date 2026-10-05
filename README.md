# diagnostics-prototype

32113 Advanced Database — Assignment 2 — Group 3  
Junseog (A) · Phuoc (B) · Zeming (E)

Data warehouse prototype for **MedScan Diagnostics**: three source systems → Bronze → Silver → Gold → Dashboard views, with a SQL-based Master Patient Index (MPI) in between.

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────┐
│  SOURCE SYSTEMS (raw, as-is)                             │
│  lis_a  — legacy pathology LIS  (text dates, local codes)│
│  lis_b  — modern pathology LIS  (ISO timestamps, LOINC)  │
│  ris    — radiology system      (DICOM accession numbers)│
└────────────────────┬─────────────────────────────────────┘
                     │ 03_load_bronze.py  (full snapshot)
                     ▼
┌──────────────────────────────────────────────────────────┐
│  BRONZE  — raw copy, no changes, adds batch_id+timestamp │
│  bronze.lis_a_patient / lis_a_request / lis_a_result     │
│  bronze.lis_b_patients / lis_b_episodes / lis_b_obs...   │
│  bronze.ris_patient / ris_exam_order / ris_report        │
└────────────────────┬─────────────────────────────────────┘
                     │ 04_build_silver.py  (clean + conform)
                     ▼
┌──────────────────────────────────────────────────────────┐
│  SILVER  — cleaned, one schema for all three sources     │
│  silver.patient_source    (one row per source patient)   │
│  silver.diagnostic_request + pathology_result            │
│  silver.imaging_report                                   │
│            │                                             │
│            │ 05_resolve_identity.sql  (MPI)              │
│            ▼                                             │
│  silver.patient      (golden patient, one per person)    │
│  silver.patient_xref (source record → golden patient)    │
└────────────────────┬─────────────────────────────────────┘
                     │ 07_load_gold.py
                     ▼
┌──────────────────────────────────────────────────────────┐
│  GOLD  — star schema, no PII, dashboards read only this  │
│  dim: patient · date · site · referrer · test · proc     │
│  fact: fact_pathology_result · fact_imaging_study        │
└────────────────────┬─────────────────────────────────────┘
                     │ 08_dashboard_views.sql
                     ▼
┌──────────────────────────────────────────────────────────┐
│  DASHBOARD VIEWS  (dashboard schema)                     │
│  v_turnaround  ·  v_abnormal_rate  ·  v_mpi_impact       │
└──────────────────────────────────────────────────────────┘
```

### Why each layer exists

| Layer | Purpose |
|---|---|
| **Bronze** | Preserve the source data exactly as received. If something breaks downstream you can re-process from here without touching the source systems. |
| **Silver** | One conformed schema regardless of which source the data came from. Dates are real timestamps, sex codes are M/F/U, priorities are ROUTINE/URGENT. Patient identity is resolved here. |
| **Gold** | Star schema optimised for reporting. No names, DOB or Medicare numbers — only surrogate keys and anonymised attributes. This is the only layer the dashboards touch. |
| **Dashboard** | Pre-aggregated views so a BI tool or CloudBeaver query returns results instantly without re-joining the facts every time. |

---

### How the MPI works

The same real patient appears in all three source systems under different IDs (different numbers, different name formats). The MPI's job is to link them into one **golden patient**.

Step 05 (`05_resolve_identity.sql`) runs two matching tiers:

| Tier | Rule | Match basis |
|---|---|---|
| 1 | Same Medicare number **and** same date of birth | `medicare+dob` |
| 2 | Same surname + first given name + DOB + sex (only when no Medicare) | `name+dob+sex` |
| 0 | No link found — patient only in one system | `unmatched (single source)` |

Result on the synthetic dataset: **108 raw identifiers → 63 golden patients** (45 duplicates collapsed, 41.7% collapse rate).

---

## File map

```
pipeline/
  01_source_schemas.sql    source + silver + audit DDL, sample rows, code map     A
  02_synthetic_data.sql    ~60 fake patients spread across the 3 systems           A
  03_load_bronze.py        full-snapshot copy: source → bronze                    E
  04_build_silver.py       clean + conform: bronze → silver                       E
  05_resolve_identity.sql  MPI: patient_source → silver.patient + patient_xref    A
  06_gold_schema.sql       star schema DDL (6 dims + 2 facts)                     A
  07_load_gold.py          silver → gold                                           A
  08_dashboard_views.sql   3 dashboard views in dashboard schema                  B

tests/
  validate_data_layer.sql  bronze→silver row counts + silver domain checks        B
  validate_mpi.sql         xref completeness + Medicare safety + tier breakdown   B
  validate_schema.py       gold structure, FK integrity, no nulls, no negatives   A

run_pipeline.py            runs all 8 steps then all 3 tests in order
docker-compose.yml         postgres 15 · cloudbeaver · python  (3 services)
```

---

## Quick start

### Requirements
- Docker Desktop installed and running
- Git

### 1. Clone and start containers

```bash
git clone https://github.com/PhuocTran-code/diagnostics-prototype.git
cd diagnostics-prototype
docker compose up -d
```

Verify three containers are up:

```bash
docker compose ps
# student-postgres      Up
# student-cloudbeaver   Up
# student-python        Up
```

### 2. Run the full pipeline

```bash
docker compose run --rm python python run_pipeline.py
```

This single command runs all 8 pipeline steps and all 3 validation tests in order. The expected output at the end looks like this:

```
----- tests/validate_data_layer.sql
source_table       | bronze_rows | silver_rows | dropped | status
lis_a patients     | 49          | 49          | 0       | OK
lis_a requests     | 201         | 201         | 0       | OK
lis_a results      | 539         | 539         | 0       | OK
lis_b episodes     | 119         | 119         | 0       | OK
lis_b observations | 330         | 330         | 0       | OK
lis_b patients     | 31          | 31          | 0       | OK
ris exam orders    | 53          | 53          | 0       | OK
ris patients       | 28          | 28          | 0       | OK
ris reports        | 51          | 51          | 0       | OK

----- tests/validate_mpi.sql
match_basis               | source_records | pct
medicare+dob              | 67             | 62.0
unmatched (single source) | 29             | 26.9
name+dob+sex              | 12             | 11.1

----- tests/validate_schema.py
[PASS] gold has all 8 tables from the design
... (25 PASS lines) ...
All schema validation tests passed.

=== done
```

### 3. Browse data in CloudBeaver

1. Open **http://localhost:8978** in your browser
2. Create a new PostgreSQL connection:
   - Host: `postgres` · Port: `5432` · Database: `medscan`
   - User: `student` · Password: `student`
3. Useful schemas to explore:

| Schema | What is in it |
|---|---|
| `lis_a / lis_b / ris` | Raw source tables as inserted by steps 01 and 02 |
| `bronze` | Full snapshot copy — same columns as source + `batch_id` and `ingested_at` |
| `silver` | Cleaned and conformed data; `patient_xref` shows how source records link to golden patients |
| `gold` | Star schema — 6 dimension tables and 2 fact tables |
| `dashboard` | Three views: `v_turnaround`, `v_abnormal_rate`, `v_mpi_impact` |
| `audit` | One row per load step, shows `rows_read` vs `rows_loaded` and run status |

### 4. Query the dashboard views

Open a SQL editor in CloudBeaver and try:

```sql
-- Turnaround time (avg / p50 / p90) by site, priority, and request type
SELECT * FROM dashboard.v_turnaround;

-- Abnormal result rate (pathology) and critical finding rate (imaging)
SELECT * FROM dashboard.v_abnormal_rate;

-- MPI impact: raw source records vs golden patients
SELECT * FROM dashboard.v_mpi_impact;
```

### 5. Run one step at a time (optional)

Useful when you want to inspect the database state between layers:

```bash
# Helper — run a SQL file directly against medscan
P="docker exec -i student-postgres psql -U student -d medscan -v ON_ERROR_STOP=1 -f -"

$P < pipeline/01_source_schemas.sql
$P < pipeline/02_synthetic_data.sql
docker compose exec python python /workspace/pipeline/03_load_bronze.py
docker compose exec python python /workspace/pipeline/04_build_silver.py
$P < pipeline/05_resolve_identity.sql
$P < pipeline/06_gold_schema.sql
docker compose exec python python /workspace/pipeline/07_load_gold.py
$P < pipeline/08_dashboard_views.sql

$P < tests/validate_data_layer.sql
$P < tests/validate_mpi.sql
docker compose exec python python /workspace/tests/validate_schema.py
```

### 6. Reset and re-run from scratch

```bash
docker compose down -v     # destroys the postgres volume — all data is wiped
docker compose up -d
docker compose run --rm python python run_pipeline.py
```

---

## Understanding the validation output

### validate_data_layer.sql

Two queries run internally. Only the row-count reconciliation table is printed:

| Column | Meaning |
|---|---|
| `bronze_rows` | Row count in the bronze snapshot table |
| `silver_rows` | Row count that made it into the silver table |
| `dropped` | Difference — should be **0** for all tables |
| `status` | `OK` = no loss · `LOSS` = rows dropped (investigate!) · `GAIN` = unexpected extra rows |

A hidden first query also runs six domain checks on silver (priority, status, sex code, abnormal flag, final requests without a date, orphan requests). If any check finds a bad value the pipeline will throw an error.

### validate_mpi.sql

First query (not printed) — four columns that must all be **0**:

| Column | What it checks |
|---|---|
| `unresolved_source_records` | Every source patient has exactly one xref entry |
| `dangling_xref_rows` | Every xref row points to a valid golden patient in silver.patient |
| `split_medicare_numbers` | One Medicare number cannot map to two different golden patients |
| `silver_gold_discrepancy` | Golden patient count in silver matches `gold.dim_patient` |

Second query (printed) — match-basis distribution showing how many records were resolved by Tier 1 (Medicare+DOB) vs Tier 2 (name+DOB+sex) vs unmatched.

### validate_schema.py

25 automated checks across gold structure and FK integrity. All 25 must show `[PASS]`. A `[FAIL]` means a broken foreign key or a missing required column in the gold layer.

---

## Working rules

- **Pull before you start:** `git pull`
- Only edit files assigned to you — ping the owner before touching theirs
- **Before pushing:** reset and re-run the full pipeline — every test must pass:
  ```bash
  docker compose down -v && docker compose up -d
  docker compose run --rm python python run_pipeline.py
  ```
- Do **not** rename or remove columns on `silver.patient`, `silver.patient_source`, or `silver.patient_xref` without telling the team — gold and the MPI both depend on them
