# Diagnostics Prototype

**32113 Advanced Database — Assignment 2 | Spring 2026**
**Team:** A (Junseog Lee) · B (Phuoc Tran) · E (Zeming Liu)

A working prototype of a pathology and radiology data warehouse using a medallion architecture (Bronze → Silver → Graph → Gold → Dashboard).

## Architecture

Three source systems (`lis_a`, `lis_b`, `ris`) → Bronze (raw) → Silver (conformed) → Neo4j Graph MPI (identity resolution) → Gold star schema → Dashboard views.

See [`docs/medallion_architecture.html`](docs/medallion_architecture.html) for the full architecture diagram and data models.

## Repository Structure

```
sql/
  01_source_schemas.sql   # Source DDL + silver + audit schemas  [A]
  02_gold_schema.sql      # Gold star schema                     [A]
etl/
  01_load_bronze.py       # Raw landing ETL                      [E]
  02_build_silver.py      # Clean & conform ETL                  [E]
  03_export_to_neo4j.py   # Graph MPI + crosswalk write-back     [B]
cypher/
  graph_mpi.cypher        # Neo4j identity resolution            [B]
dashboards/
  views.sql               # D1 turnaround · D2 abnormal · D3 MPI [B]
tests/
  validate_schema.sql     # Schema & gold validation             [A]
  validate_data_layer.sql # Bronze→silver reconciliation         [E]
  validate_mpi.sql        # Graph crosswalk checks               [B]
docs/
  medallion_architecture.html
```

## Quick Start

```bash
git clone https://github.com/PhuocTran-code/diagnostics-prototype.git
cd diagnostics-prototype
docker compose up -d
docker ps   # postgres, neo4j, clickhouse, cloudbeaver, python all running
```

Then run scripts in order — see `TEAM_WORKFLOW_GUIDE.md` for the full daily workflow.

## Pipeline Run Order

```bash
docker compose exec python python /workspace/sql_runner.py sql/01_source_schemas.sql
docker compose exec python python /workspace/sql_runner.py sql/02_gold_schema.sql
docker compose exec python python /workspace/etl/01_load_bronze.py
docker compose exec python python /workspace/etl/02_build_silver.py
docker compose exec python python /workspace/etl/03_export_to_neo4j.py
docker compose exec python python /workspace/sql_runner.py dashboards/views.sql
```
