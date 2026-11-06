-- P2 Step 4: Acceptance checks on the implemented Raw -> Curated path
-- Chicago Taxi Shift & Demand Planner (SEIS 732-02)
--
-- Read-only: no object is created or changed. Run after sql/03_curate.sql:
--   bq query --use_legacy_sql=false --maximum_bytes_billed=10000000000 < sql/04_acceptance.sql
-- Each check returns one result row with a PASS/FAIL column. Results are recorded
-- in docs/p2-build.md, section 3.


-- ---------------------------------------------------------------------------
-- CHECK A (grain and relationships) -- P1 risk R1
-- Risk: the joins in fct_trip add, drop or duplicate trips, or leave trips with
--       a key that matches no dimension row, so Q1 trip counts are wrong.
-- Method: inspect fct_trip AFTER the joins and reconcile it with Raw trip by trip.
-- Expected: fct rows = distinct trip_id = Raw rows (12,877,486); 0 Raw trips
--       missing from fct; 0 fct trips not in Raw; 0 null keys; 0 keys without a
--       dimension row; 0 guard (-1) keys.
-- ---------------------------------------------------------------------------
WITH
f AS (SELECT * FROM `savvy-primacy-249323.taxi_curated.fct_trip`),
r AS (SELECT unique_key FROM `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`),
a AS (
  SELECT
    (SELECT COUNT(*) FROM r)                                         AS raw_rows,
    (SELECT COUNT(*) FROM f)                                         AS fct_rows,
    (SELECT COUNT(DISTINCT trip_id) FROM f)                          AS fct_distinct_trip_id,
    (SELECT COUNT(*) FROM r LEFT JOIN f ON f.trip_id = r.unique_key
       WHERE f.trip_id IS NULL)                                      AS raw_trips_missing_in_fct,
    (SELECT COUNT(*) FROM f LEFT JOIN r ON f.trip_id = r.unique_key
       WHERE r.unique_key IS NULL)                                   AS fct_trips_not_in_raw,
    (SELECT COUNTIF(date_key IS NULL OR time_key IS NULL OR pickup_area_key IS NULL
                 OR dropoff_area_key IS NULL OR company_key IS NULL
                 OR taxi_key IS NULL OR payment_type_key IS NULL) FROM f) AS rows_with_null_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_date` d USING (date_key)
       WHERE d.date_key IS NULL)                                     AS orphan_date_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_time_of_day` d USING (time_key)
       WHERE d.time_key IS NULL)                                     AS orphan_time_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_community_area` d
       ON d.area_key = f.pickup_area_key WHERE d.area_key IS NULL)   AS orphan_pickup_area_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_community_area` d
       ON d.area_key = f.dropoff_area_key WHERE d.area_key IS NULL)  AS orphan_dropoff_area_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_company` d USING (company_key)
       WHERE d.company_key IS NULL)                                  AS orphan_company_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_taxi` d USING (taxi_key)
       WHERE d.taxi_key IS NULL)                                     AS orphan_taxi_key,
    (SELECT COUNT(*) FROM f LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_payment_type` d USING (payment_type_key)
       WHERE d.payment_type_key IS NULL)                             AS orphan_payment_type_key,
    (SELECT COUNTIF(company_key = -1 OR taxi_key = -1 OR payment_type_key = -1) FROM f) AS rows_with_guard_key
)
SELECT
  'A: fct_trip grain and relationships' AS check_name,
  a.*,
  IF(fct_rows = raw_rows AND fct_distinct_trip_id = fct_rows
     AND raw_trips_missing_in_fct = 0 AND fct_trips_not_in_raw = 0
     AND rows_with_null_key = 0
     AND orphan_date_key + orphan_time_key + orphan_pickup_area_key + orphan_dropoff_area_key
       + orphan_company_key + orphan_taxi_key + orphan_payment_type_key = 0
     AND rows_with_guard_key = 0, 'PASS', 'FAIL') AS result
FROM a;


-- ---------------------------------------------------------------------------
-- CHECK B (meaning of a Q1 cell) -- P1 risks R2a and R2b
-- Risk: a Q1 cell (hour of day x weekday x pickup area) in Curated does not mean
--       what the dashboard will say: a time-zone conversion moves trips to other
--       hours, the weekday or unknown-area rule is wrong, or the fare rule changes
--       which trips enter "average fare".
-- Method: compute every market cell twice and compare them cell by cell.
--   Curated side: fct_trip joined to dim_time_of_day, dim_date, dim_community_area.
--   Independent side: straight from Raw with EXTRACT on the stored timestamp,
--   FORMAT_DATE for the weekday, a NULL area test, and the fare rule on FLOAT64.
--   Plus the P1 time-zone markers taken from fct_trip.
-- Expected: 0 cells only on one side; 0 cells whose trips, fare-valid trips differ;
--   fare sums equal to the cent; peak hour 17 = 921,860 trips; 0 trips in hour 02
--   on spring-forward day 2023-03-12 (all from P1 Task 1).
-- ---------------------------------------------------------------------------
WITH
cur AS (
  SELECT t.hour_of_day, d.weekday_name, a.area_name,
         COUNT(*)                         AS trips,
         COUNTIF(f.is_fare_valid)         AS fare_valid_trips,
         SUM(IF(f.is_fare_valid, f.fare, 0)) AS fare_sum
  FROM `savvy-primacy-249323.taxi_curated.fct_trip` f
  JOIN `savvy-primacy-249323.taxi_curated.dim_time_of_day`    t USING (time_key)
  JOIN `savvy-primacy-249323.taxi_curated.dim_date`           d USING (date_key)
  JOIN `savvy-primacy-249323.taxi_curated.dim_community_area` a ON a.area_key = f.pickup_area_key
  GROUP BY 1, 2, 3
),
raw AS (
  SELECT EXTRACT(HOUR FROM trip_start_timestamp)          AS hour_of_day,
         FORMAT_DATE('%A', DATE(trip_start_timestamp))   AS weekday_name,
         pickup_community_area                             AS area,   -- NULL = unknown
         COUNT(*)                                          AS trips,
         COUNTIF(fare > 0 AND fare <= 1000)                AS fare_valid_trips,
         SUM(IF(fare > 0 AND fare <= 1000, fare, 0))       AS fare_sum
  FROM `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`
  GROUP BY 1, 2, 3
),
raw_named AS (   -- attach names only so the two sides can be joined
  SELECT r.* EXCEPT (area), IF(r.area IS NULL, 'Unknown/outside', a.area_name) AS area_name
  FROM raw r
  LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_community_area` a
    ON a.area_key = r.area
),
cmp AS (
  SELECT c.trips AS c_trips, r.trips AS r_trips,
         c.fare_valid_trips AS c_valid, r.fare_valid_trips AS r_valid,
         c.fare_sum AS c_fare, r.fare_sum AS r_fare
  FROM cur c FULL OUTER JOIN raw_named r USING (hour_of_day, weekday_name, area_name)
),
hours AS (
  SELECT t.hour_of_day, COUNT(*) AS trips
  FROM `savvy-primacy-249323.taxi_curated.fct_trip` f
  JOIN `savvy-primacy-249323.taxi_curated.dim_time_of_day` t USING (time_key)
  GROUP BY 1
),
b AS (
  SELECT
    COUNT(*)                                                        AS cells_compared,
    COUNTIF(c_trips IS NULL OR r_trips IS NULL)                     AS cells_on_one_side_only,
    COUNTIF(c_trips <> r_trips)                                     AS cells_trip_mismatch,
    COUNTIF(c_valid <> r_valid)                                     AS cells_fare_valid_mismatch,
    MAX(ABS(CAST(c_fare AS FLOAT64) - r_fare))                      AS max_cell_fare_sum_diff,
    SUM(c_trips)                                                    AS curated_trips,
    SUM(r_trips)                                                    AS raw_trips,
    ROUND(SUM(CAST(c_fare AS FLOAT64)) / SUM(c_valid), 4)           AS curated_avg_fare,
    ROUND(SUM(r_fare) / SUM(r_valid), 4)                            AS raw_avg_fare,
    (SELECT hour_of_day FROM hours ORDER BY trips DESC LIMIT 1)     AS peak_hour,
    (SELECT MAX(trips) FROM hours)                                  AS peak_hour_trips,
    (SELECT COUNT(*) FROM `savvy-primacy-249323.taxi_curated.fct_trip`
       WHERE DATE(trip_start_local) = '2023-03-12'
         AND EXTRACT(HOUR FROM trip_start_local) = 2)               AS trips_0200_2023_03_12
  FROM cmp
)
SELECT
  'B: Q1 cell meaning (hour x weekday x pickup area)' AS check_name,
  b.*,
  IF(cells_on_one_side_only = 0 AND cells_trip_mismatch = 0 AND cells_fare_valid_mismatch = 0
     AND max_cell_fare_sum_diff < 0.005 AND peak_hour = 17 AND peak_hour_trips = 921860
     AND trips_0200_2023_03_12 = 0, 'PASS', 'FAIL') AS result
FROM b;


-- ---------------------------------------------------------------------------
-- SUPPORTING (not one of the two required checks) -- P1 risk R3
-- Company attribution and name conformance. Expected values were computed in P1
-- (sql/01_source_profile.sql, Q4A) directly from the public source.
-- Expected: 5 Star Taxi 2022 = 157,880 and 2023 = 299,448; Blue Ribbon (merged)
--   2022 = 189,022 and 2023 = 205,906; year totals 6,382,071 and 6,495,415.
-- ---------------------------------------------------------------------------
SELECT
  'R3: company totals (supporting)' AS check_name,
  COUNTIF(c.company_name = '5 Star Taxi' AND d.year = 2022)                  AS five_star_2022,
  COUNTIF(c.company_name = '5 Star Taxi' AND d.year = 2023)                  AS five_star_2023,
  COUNTIF(c.company_name = 'Blue Ribbon Taxi Association' AND d.year = 2022) AS blue_ribbon_2022,
  COUNTIF(c.company_name = 'Blue Ribbon Taxi Association' AND d.year = 2023) AS blue_ribbon_2023,
  COUNTIF(d.year = 2022)                                                     AS trips_2022,
  COUNTIF(d.year = 2023)                                                     AS trips_2023,
  COUNT(DISTINCT f.company_key)                                              AS companies
FROM `savvy-primacy-249323.taxi_curated.fct_trip` f
JOIN `savvy-primacy-249323.taxi_curated.dim_company` c USING (company_key)
JOIN `savvy-primacy-249323.taxi_curated.dim_date`    d USING (date_key);
