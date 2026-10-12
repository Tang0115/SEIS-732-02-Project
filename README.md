# Chicago Taxi Shift & Demand Planner

SEIS 732-02 Data Warehousing (Fall 2026) individual data-product project.

**Current purpose (P0):** test whether the City of Chicago taxi trip data in BigQuery can support a planning dashboard for a Chicago taxi company's operations manager. The dashboard would show when and where demand and revenue are highest, how airport trips compare, and how the company's market share changes.

## P0 artifacts

- [docs/p0-feasibility.md](docs/p0-feasibility.md): need, audience, questions, source, risks, and first P1 decision
- [sql/00_feasibility.sql](sql/00_feasibility.sql): reproducible aggregate profiling queries
- [evidence/p0-feasibility-results.md](evidence/p0-feasibility-results.md): summarized results (no source rows)

## Source

`bigquery-public-data.chicago_taxi_trips.taxi_trips` (US). Data provided by the City of Chicago Data Portal ("Taxi Trips (2013-2023)"), subject to the City's Terms of Use. This repository contains queries and aggregate summaries only, never source rows or extracts.

## Running the queries

Run from your own BigQuery execution project (not `ust-732-dw`). The source table is unpartitioned (~77 GiB), so dry-run each query first and set a byte cap:

```bash
bq query --use_legacy_sql=false --dry_run < query.sql
bq query --use_legacy_sql=false --maximum_bytes_billed=45000000000 < query.sql
```
