-- P0 feasibility checks: Chicago Taxi Trips
-- Source: bigquery-public-data.chicago_taxi_trips.taxi_trips (US multi-region)
-- Execution project: the student-owned SEIS 732 project (not ust-732-dw).
--
-- Aggregate-only profiling. No row-level output is saved to the repository.
-- Every query was dry-run first; estimated bytes are noted above each one.
-- taxi_trips is NOT partitioned or clustered, so a date filter does not reduce
-- bytes scanned. Each query selects only the columns it needs.
--
-- Dataset location was read from metadata, not a query:
--   bq show --format=prettyjson bigquery-public-data:chicago_taxi_trips
--   (location: US)
-- Results are summarized in evidence/p0-feasibility-results.md.

-- 1. Objects available in the source dataset. (~10 MB, metadata)
SELECT table_name, table_type, creation_time
FROM `bigquery-public-data.chicago_taxi_trips.INFORMATION_SCHEMA.TABLES`;

-- 2. Column definitions of the candidate table. (~10 MB, metadata)
SELECT column_name, data_type, is_nullable, is_partitioning_column, clustering_ordinal_position
FROM `bigquery-public-data.chicago_taxi_trips.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'taxi_trips'
ORDER BY ordinal_position;

-- 3. Scale, storage size, and last modification. (0 bytes, metadata)
SELECT table_id, row_count, ROUND(size_bytes / POW(1024, 3), 2) AS size_gib,
       TIMESTAMP_MILLIS(last_modified_time) AS last_modified
FROM `bigquery-public-data.chicago_taxi_trips.__TABLES__`;

-- 4. Time coverage and candidate keys. (~38.4 GB; unique_key is the costly column)
SELECT
    COUNT(*) AS row_count,
    MIN(trip_start_timestamp) AS earliest_start,
    MAX(trip_start_timestamp) AS latest_start,
    COUNTIF(unique_key IS NULL) AS null_unique_keys,
    COUNT(DISTINCT unique_key) AS distinct_unique_keys,
    COUNT(DISTINCT taxi_id) AS distinct_taxi_ids,
    COUNTIF(taxi_id IS NULL) AS null_taxi_ids
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`;

-- 5. Null rates for fields the questions depend on. (~19.2 GB)
SELECT
    COUNT(*) AS row_count,
    ROUND(COUNTIF(trip_end_timestamp IS NULL) / COUNT(*), 4) AS null_end_ts,
    ROUND(COUNTIF(trip_seconds IS NULL) / COUNT(*), 4) AS null_trip_seconds,
    ROUND(COUNTIF(trip_miles IS NULL) / COUNT(*), 4) AS null_trip_miles,
    ROUND(COUNTIF(fare IS NULL) / COUNT(*), 4) AS null_fare,
    ROUND(COUNTIF(tips IS NULL) / COUNT(*), 4) AS null_tips,
    ROUND(COUNTIF(trip_total IS NULL) / COUNT(*), 4) AS null_trip_total,
    ROUND(COUNTIF(payment_type IS NULL) / COUNT(*), 4) AS null_payment_type,
    ROUND(COUNTIF(company IS NULL) / COUNT(*), 4) AS null_company,
    ROUND(COUNTIF(pickup_community_area IS NULL) / COUNT(*), 4) AS null_pickup_area,
    ROUND(COUNTIF(dropoff_community_area IS NULL) / COUNT(*), 4) AS null_dropoff_area
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`;

-- 6. Trips and reporting companies per year: coverage gaps and trend. (~5.8 GB)
SELECT EXTRACT(YEAR FROM trip_start_timestamp) AS trip_year,
       COUNT(*) AS trips,
       COUNT(DISTINCT company) AS companies
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
GROUP BY trip_year
ORDER BY trip_year;

-- 7. Timestamp granularity: are start times rounded to 15-minute marks? (~1.7 GB)
SELECT EXTRACT(MINUTE FROM trip_start_timestamp) AS start_minute,
       COUNT(*) AS trips
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= '2023-01-01'
GROUP BY start_minute
ORDER BY start_minute;

-- 8. Company field quality (2023+): how many names, how concentrated. (~5.8 GB)
SELECT COUNT(DISTINCT company) AS distinct_companies,
       APPROX_TOP_COUNT(company, 10) AS top_companies
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= '2023-01-01';

-- 9. Payment types, tips, and implausible values (2023+). (~10.4 GB)
SELECT payment_type,
       COUNT(*) AS trips,
       ROUND(AVG(tips), 2) AS avg_tips,
       COUNTIF(fare <= 0) AS nonpositive_fares,
       COUNTIF(trip_seconds <= 0) AS nonpositive_seconds,
       COUNTIF(trip_total > 1000) AS totals_over_1000
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= '2023-01-01'
GROUP BY payment_type
ORDER BY trips DESC;

-- 10. Airport trips (2023+): community area 76 = O'Hare; 56 = Garfield Ridge,
--     which contains Midway but also non-airport neighborhoods. (~9.8 GB)
SELECT
    CASE
        WHEN pickup_community_area = 76 OR dropoff_community_area = 76 THEN 'OHare'
        WHEN pickup_community_area = 56 OR dropoff_community_area = 56 THEN 'Midway area'
        ELSE 'Other'
    END AS trip_group,
    COUNT(*) AS trips,
    ROUND(AVG(fare), 2) AS avg_fare,
    ROUND(AVG(tips), 2) AS avg_tips,
    ROUND(AVG(trip_seconds) / 60, 1) AS avg_minutes
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= '2023-01-01'
GROUP BY trip_group
ORDER BY trips DESC;
