# Chicago Taxi Shift & Demand Planner

SEIS 732-02 Data Warehousing (Fall 2026) individual data-product project.

**Purpose:** a planning dashboard for a Chicago taxi company's operations manager, built on City of Chicago taxi trip data in BigQuery. It shows when and where trips and average fares are highest, for one company compared with the whole market, and how the company's share of reported taxi trips changes.

The product is a **historical planning baseline (2022–2023)**, not a live operations tool: the source ends 2023-12-31.

## P1 artifacts

- [docs/p1-plan.md](docs/p1-plan.md): question, source check and grain test, dimensional model, history decision, build plan and checks
- [docs/model.svg](docs/model.svg): dimensional model diagram
- [sql/01_source_profile.sql](sql/01_source_profile.sql): reproducible grain, time-zone and company-history checks

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
