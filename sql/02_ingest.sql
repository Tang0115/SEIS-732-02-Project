-- P2 Step 1-2: Source -> Raw
-- Chicago Taxi Shift & Demand Planner (SEIS 732-02)
--
-- Source : bigquery-public-data.chicago_taxi_trips.taxi_trips  (US multi-region, unpartitioned)
-- Target : savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023  (US)
-- Subset : trips with trip_start_timestamp in [2022-01-01, 2024-01-01)
--
-- Behaviour: CREATE SCHEMA IF NOT EXISTS leaves existing datasets alone.
--            CREATE OR REPLACE TABLE fully REPLACES the Raw table on every run
--            (no append). The source is static (ends 2023-12-31), so a re-run
--            reproduces the same rows; only _loaded_at changes.
-- Cost:      the source is unpartitioned, so the date filter does not prune.
--            The CTAS reads every source column once (dry-run: see docs/p2-build.md).
--            Run with:  bq query --use_legacy_sql=false --dry_run < sql/02_ingest.sql
--                       bq query --use_legacy_sql=false --maximum_bytes_billed=90000000000 < sql/02_ingest.sql
-- Results recorded in docs/p2-build.md. No source rows are stored in this repository.


-- 1. Datasets (one per layer). Location must match the source (US).
CREATE SCHEMA IF NOT EXISTS `savvy-primacy-249323.taxi_raw`
  OPTIONS (location = 'US', description = 'P2 Raw layer: unchanged copy of the 2022-2023 taxi trip window');
CREATE SCHEMA IF NOT EXISTS `savvy-primacy-249323.taxi_curated`
  OPTIONS (location = 'US', description = 'P2 Curated layer: typed trip fact and conformed dimensions');
CREATE SCHEMA IF NOT EXISTS `savvy-primacy-249323.taxi_serving`
  OPTIONS (location = 'US', description = 'P3 Serving layer (created now, filled in P3)');


-- 2. Raw: all 23 source columns, values and types unchanged, plus two load columns.
--    Partitioned by trip start date so later steps scan only the dates they need;
--    clustered on the two columns Q1 filters and groups by.
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`
PARTITION BY DATE(trip_start_timestamp)
CLUSTER BY company, pickup_community_area
OPTIONS (description = 'Unchanged copy of bigquery-public-data.chicago_taxi_trips.taxi_trips, trips starting 2022-01-01 to 2023-12-31. One row = one source row (one reported trip).')
AS
SELECT
  src.*,
  'bigquery-public-data.chicago_taxi_trips.taxi_trips' AS _source_table,
  CURRENT_TIMESTAMP() AS _loaded_at
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips` AS src
WHERE src.trip_start_timestamp >= TIMESTAMP '2022-01-01'
  AND src.trip_start_timestamp <  TIMESTAMP '2024-01-01';


-- 3. Load record (cheap: reads only the Raw copy). Result goes in docs/p2-build.md.
SELECT
  COUNT(*)                                 AS raw_rows,
  COUNT(DISTINCT unique_key)               AS distinct_unique_key,
  COUNTIF(unique_key IS NULL)              AS null_unique_key,
  MIN(trip_start_timestamp)                AS min_start,
  MAX(trip_start_timestamp)                AS max_start,
  COUNTIF(EXTRACT(YEAR FROM trip_start_timestamp) = 2022) AS rows_2022,
  COUNTIF(EXTRACT(YEAR FROM trip_start_timestamp) = 2023) AS rows_2023,
  MIN(_loaded_at)                          AS loaded_at
FROM `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`;
