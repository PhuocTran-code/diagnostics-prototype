# diagnostics-prototype

32113 Advanced Database, Assignment 2, Group 3
Prototype: Junseog (A), Phuoc (B), Zeming (E)

Data warehouse prototype for MedScan Diagnostics. Same idea as Workshop 6:
3 source systems -> bronze -> silver -> gold -> dashboard views.
Patient matching (MPI) happens in silver, in SQL.

Architecture / data model: docs/medallion_architecture.html

## Files

Numbers = run order.

```
pipeline/
  01_source_schemas.sql    source tables (lis_a, lis_b, ris) + silver/audit tables + code map   A
  02_synthetic_data.sql    fake data, about 60 patients spread over the 3 systems             A
  03_load_bronze.py        copy sources into bronze as-is                                      E
  04_build_silver.py       clean up: dates, sex, status, LOINC codes, one table per entity     E
  05_resolve_identity.sql  patient matching -> silver.patient + silver.patient_xref            B
  06_gold_schema.sql       star schema DDL                                                     A
  07_load_gold.py          silver -> gold                                                      A
  08_dashboard_views.sql   dashboard views (TODO)                                              B
tests/
  validate_data_layer.sql  source/bronze/silver row counts, orphans, conforming                E
  validate_mpi.sql         matching checked against the synthetic ground truth                 B
  validate_schema.py       gold matches the design, FK integrity (workshop style checks)       A
run_pipeline.py            runs everything above in order and prints the test results
```

Gold only reads silver.patient and silver.patient_xref for patients. If the matching
logic changes, those two tables have to keep the same columns.

## How to run

```
git clone https://github.com/PhuocTran-code/diagnostics-prototype.git
cd diagnostics-prototype
docker compose up -d
docker compose run --rm python python run_pipeline.py
```

Database is `medscan` (created by the runner if missing, so it also works on the
workshop stack without touching `lab`). Override with PGDATABASE=... if needed.

Or one file at a time:

```
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

CloudBeaver: http://localhost:8978, host postgres, port 5432, user/pw student.

## Working rules

- own docker stack each, no shared db
- git pull first, only touch your own files, ping the owner otherwise
- before push: `docker compose down -v && docker compose up -d`, then `./run_pipeline.sh`, every test row should be PASS
- don't change columns on silver.patient_source / silver.patient / silver.patient_xref without telling the others
