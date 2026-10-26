-- P1 source profile and grain checks: Chicago Taxi Trips
-- Source: bigquery-public-data.chicago_taxi_trips.taxi_trips (US multi-region)
-- Execution project: the student-owned SEIS 732 project (not ust-732-dw).
--
-- Aggregate-only output. No row-level results are saved to the repository.
-- Results are recorded in docs/p1-plan.md (run date 2026-10-25).
-- Each query was dry-run first and run with --maximum_bytes_billed.
-- taxi_trips is unpartitioned, so the date filters below do not reduce
-- bytes scanned; only the column list does.
--
-- Analysis window used throughout: trip_start_timestamp in [2022-01-01, 2024-01-01).
-- Queries reused from P0 (sql/00_feasibility.sql): 4 (row count, coverage),
-- 6 (trips per year) and 9 (payment types).


-- 1. Grain check: does unique_key identify one trip row?  (~10.7 GB)
--    Proposed grain: one row per unique_key.
--    Expected if unique_key is a trip ID: 0 null keys, 0 repeated groups.
--    The ROLLUP row with first_year = NULL is the full-table total; the other
--    rows split the repeated keys by year. The window_* columns restrict the
--    same test to the 2022-2023 analysis window.
WITH grain_groups AS (
  SELECT
    unique_key,
    COUNT(*) AS rows_per_id,
    COUNTIF(trip_start_timestamp >= TIMESTAMP '2022-01-01'
        AND trip_start_timestamp <  TIMESTAMP '2024-01-01') AS window_rows_per_id,
    MIN(EXTRACT(YEAR FROM trip_start_timestamp)) AS first_year,
    MAX(EXTRACT(YEAR FROM trip_start_timestamp)) AS last_year
  FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
  GROUP BY unique_key
)
SELECT
  first_year,
  COALESCE(SUM(rows_per_id), 0) AS source_rows,
  COALESCE(SUM(IF(unique_key IS NULL, rows_per_id, 0)), 0) AS rows_with_null_id,
  COUNTIF(unique_key IS NOT NULL AND rows_per_id > 1) AS repeated_id_groups,
  COALESCE(SUM(IF(rows_per_id > 1, rows_per_id - 1, 0)), 0) AS excess_rows,
  MAX(rows_per_id) AS max_rows_per_id,
  COUNTIF(rows_per_id > 1 AND first_year <> last_year) AS repeated_groups_spanning_years,
  COALESCE(SUM(window_rows_per_id), 0) AS window_rows,
  COUNTIF(unique_key IS NOT NULL AND window_rows_per_id > 1) AS window_repeated_id_groups,
  COALESCE(SUM(IF(window_rows_per_id > 1, window_rows_per_id - 1, 0)), 0) AS window_excess_rows,
  COUNTIF(window_rows_per_id >= 1 AND rows_per_id > window_rows_per_id) AS window_keys_also_outside
FROM grain_groups
GROUP BY ROLLUP(first_year)
ORDER BY first_year;


-- 2. Window counters: time-zone meaning, date roles, nulls in fact fields.  (~14.1 GB)
--    Time-zone test: the column type is TIMESTAMP (UTC), but if the stored value
--    is really Chicago wall-clock time, no trip can start at 02:xx on a
--    spring-forward Sunday (that local hour does not exist), and 01:xx on the
--    fall-back Sunday occurs twice. Neighbouring Sundays are the comparison.
WITH w AS (
  SELECT trip_start_timestamp AS s, trip_end_timestamp AS e,
         pickup_community_area, company, trip_total, trip_seconds, fare
  FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
  WHERE trip_start_timestamp >= TIMESTAMP '2022-01-01'
    AND trip_start_timestamp <  TIMESTAMP '2024-01-01'
)
SELECT
  COUNT(*) AS window_rows,
  -- spring-forward days: local 02:00-02:59 does not exist in America/Chicago
  COUNTIF(DATE(s) = '2022-03-13' AND EXTRACT(HOUR FROM s) = 2) AS h2_2022_03_13,
  COUNTIF(DATE(s) = '2022-03-06' AND EXTRACT(HOUR FROM s) = 2) AS h2_2022_03_06,
  COUNTIF(DATE(s) = '2022-03-20' AND EXTRACT(HOUR FROM s) = 2) AS h2_2022_03_20,
  COUNTIF(DATE(s) = '2023-03-12' AND EXTRACT(HOUR FROM s) = 2) AS h2_2023_03_12,
  COUNTIF(DATE(s) = '2023-03-05' AND EXTRACT(HOUR FROM s) = 2) AS h2_2023_03_05,
  COUNTIF(DATE(s) = '2023-03-19' AND EXTRACT(HOUR FROM s) = 2) AS h2_2023_03_19,
  -- fall-back days: local 01:00-01:59 occurs twice
  COUNTIF(DATE(s) = '2023-11-05' AND EXTRACT(HOUR FROM s) = 1) AS h1_2023_11_05,
  COUNTIF(DATE(s) = '2023-10-29' AND EXTRACT(HOUR FROM s) = 1) AS h1_2023_10_29,
  COUNTIF(DATE(s) = '2023-11-12' AND EXTRACT(HOUR FROM s) = 1) AS h1_2023_11_12,
  -- date roles: how often start and end fall on different dates or months
  COUNTIF(e IS NULL) AS null_end,
  COUNTIF(DATE(e) <> DATE(s)) AS end_date_differs,
  COUNTIF(DATE_TRUNC(DATE(e), MONTH) <> DATE_TRUNC(DATE(s), MONTH)) AS end_month_differs,
  COUNTIF(e < s) AS end_before_start,
  -- nulls and exclusion candidates on fields the primary question uses
  COUNTIF(pickup_community_area IS NULL) AS null_pickup_area,
  COUNTIF(company IS NULL) AS null_company,
  COUNTIF(trip_total IS NULL) AS null_trip_total,
  COUNTIF(trip_seconds IS NULL OR trip_seconds <= 0) AS nonpositive_or_null_seconds,
  COUNTIF(fare IS NULL OR fare <= 0) AS nonpositive_or_null_fare,
  COUNTIF(trip_total > 1000) AS total_over_1000
FROM w;


-- 3. Hour-of-day profile as stored (2022-2023).  (~1.7 GB)
--    If the values were true UTC, the local evening peak would appear at
--    stored hours 22-00. A peak at 17 means the values are local wall-clock.
SELECT EXTRACT(HOUR FROM trip_start_timestamp) AS stored_hour, COUNT(*) AS trips
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= TIMESTAMP '2022-01-01'
  AND trip_start_timestamp <  TIMESTAMP '2024-01-01'
GROUP BY stored_hour
ORDER BY stored_hour;


-- 4. History check: does a taxi's company change, and does the treatment matter?
--    BigQuery script. The temp table reads the source once (~33.5 GB); the
--    statements after it read only the temp table (~2 GB each).
--    Run on 2026-10-25 as two scripts with the same temp table: first 4A, then
--    4B-4D. (4B also ran in the first script, but its array column could not
--    be printed as CSV; use --format=prettyjson.)
--    Set --maximum_bytes_billed for the whole script (about 40 GB), not per statement.
--    Note: "most recent company" uses ORDER BY ts DESC; ties at the same
--    15-minute timestamp are broken arbitrarily, so re-runs can differ by a
--    handful of trips.
CREATE TEMP TABLE t AS
SELECT taxi_id, company, trip_start_timestamp AS ts, trip_total
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= TIMESTAMP '2022-01-01'
  AND trip_start_timestamp <  TIMESTAMP '2024-01-01';

-- 4A. Trips per company and year under two treatments:
--     as_of = company recorded on the trip itself (event-time; planned choice)
--     type1 = taxi's most recent company applied to all of its trips (overwrite)
WITH taxi AS (
  SELECT taxi_id,
         ARRAY_AGG(company ORDER BY ts DESC LIMIT 1)[OFFSET(0)] AS current_company
  FROM t GROUP BY taxi_id
),
j AS (
  SELECT t.*, taxi.current_company
  FROM t JOIN taxi USING (taxi_id)
)
SELECT
  company_name,
  EXTRACT(YEAR FROM ts) AS yr,
  SUM(as_of_trips) AS as_of_trips,
  SUM(type1_trips) AS type1_trips
FROM (
  SELECT company AS company_name, ts, 1 AS as_of_trips, 0 AS type1_trips FROM j
  UNION ALL
  SELECT current_company, ts, 0, 1 FROM j
)
GROUP BY company_name, yr
ORDER BY company_name, yr;

-- 4B. How many taxis record more than one company, and how often they change.
WITH taxi AS (
  SELECT taxi_id, COUNT(*) AS trips, COUNT(DISTINCT company) AS companies_seen
  FROM t GROUP BY taxi_id
),
runs AS (
  SELECT taxi_id, COUNTIF(company <> prev) AS changes
  FROM (SELECT taxi_id, company,
               LAG(company) OVER (PARTITION BY taxi_id ORDER BY ts) AS prev
        FROM t)
  GROUP BY taxi_id
)
SELECT
  COUNT(*) AS taxis,
  COUNTIF(companies_seen > 1) AS taxis_multi_company,
  SUM(trips) AS trips,
  SUM(IF(companies_seen > 1, trips, 0)) AS trips_by_multi_company_taxis,
  APPROX_QUANTILES(IF(companies_seen > 1, changes, NULL), 4) AS changes_quartiles_multi,
  MAX(changes) AS max_changes,
  COUNTIF(changes >= 5) AS taxis_5plus_changes
FROM taxi JOIN runs USING (taxi_id);

-- 4C. Rename or real move? Date span and taxi count of each similar name.
SELECT company, MIN(DATE(ts)) AS first_date, MAX(DATE(ts)) AS last_date,
       COUNT(DISTINCT taxi_id) AS taxis, COUNT(*) AS trips
FROM t
WHERE REGEXP_CONTAINS(LOWER(company),
      r'blue ribbon|choice taxi|koam|taxicab insurance|top cab|taxi affiliation services')
GROUP BY company
ORDER BY company;

-- 4D. Company-to-company switches. A rename shows as many taxis switching
--     on one cut-over date; a real move is spread over many dates.
WITH seq AS (
  SELECT taxi_id, company, prev, DATE(ts) AS d
  FROM (SELECT taxi_id, company, ts,
               LAG(company) OVER (PARTITION BY taxi_id ORDER BY ts) AS prev
        FROM t)
  WHERE company <> prev
)
SELECT prev AS from_company, company AS to_company,
       COUNT(*) AS switches, COUNT(DISTINCT taxi_id) AS taxis,
       MIN(d) AS first_switch, MAX(d) AS last_switch,
       APPROX_TOP_COUNT(d, 1)[OFFSET(0)].value AS modal_date,
       APPROX_TOP_COUNT(d, 1)[OFFSET(0)].count AS modal_date_switches
FROM seq
GROUP BY from_company, to_company
HAVING switches >= 20
ORDER BY switches DESC
LIMIT 25;
