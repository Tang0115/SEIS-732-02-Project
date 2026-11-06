-- P2 Step 3: Raw -> Curated
-- Chicago Taxi Shift & Demand Planner (SEIS 732-02)
--
-- Input : savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023  (built by sql/02_ingest.sql)
-- Output: savvy-primacy-249323.taxi_curated.*   (US)
--
-- Behaviour: every statement is CREATE OR REPLACE, so a run fully REPLACES the
--            Curated objects. Nothing appends. Run the whole file as one script:
--              bq query --use_legacy_sql=false --maximum_bytes_billed=10000000000 < sql/03_curate.sql
--            Order inside the file matters: company_name_fix, then dim_company
--            and company_name_map (both read Raw), the other seeds and generated
--            dimensions, the trip_clean view, dim_taxi, and finally fct_trip.
-- Reads only the Raw copy, never the public source.
--
-- Grain of fct_trip: one row per distinct reported trip (source unique_key)
-- starting 2022-01-01 00:00 to 2023-12-31 23:45 Chicago local time.
-- Results recorded in docs/p2-build.md.


-- ---------------------------------------------------------------------------
-- 1. Seed: company_name_fix (business-name conformance rules only)
--    Merge rule (P1): merge only when names differ by case, punctuation or a
--    legal suffix. Also repairs two truncated source strings.
--    Not merged: Top Cab vs Top Cab Affiliation; Taxi Affiliation Services vs
--    "... Llc - Yell". Every source name not listed here keeps its own name.
--    No owner-operator name is written in this file: those names (some contain
--    a person's name) are read from Raw inside BigQuery and never leave it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.company_name_fix` AS
SELECT * FROM UNNEST([
  STRUCT('Blue Ribbon Taxi Association Inc.' AS source_company, 'Blue Ribbon Taxi Association' AS company_name),
  ('Choice Taxi Association Inc',          'Choice Taxi Association'),
  ('Koam Taxi Association',                'KOAM Taxi Association'),
  ('Taxicab Insurance Agency Llc',         'Taxicab Insurance Agency LLC'),
  ('Taxicab Insurance Agency, LLC',        'Taxicab Insurance Agency LLC'),
  ('Medallion Leasin',                     'Medallion Leasing'),                       -- truncated in source
  ('Patriot Taxi Dba Peace Taxi Associat', 'Patriot Taxi Dba Peace Taxi Association')  -- truncated in source
]);


-- ---------------------------------------------------------------------------
-- 2. company_name_map (every distinct Raw spelling -> conformed company_name)
--    and dim_company (one row per conformed company + guard row -1).
--    company_key = ROW_NUMBER over the conformed name. The source is static, so
--    the key set is stable across rebuilds of the same Raw input.
--    is_owner_operator: source names of the form "<4-digit medallion> - ...".
--    display_name hides owner-operator names in everything built for the audience.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.dim_company` AS
WITH names AS (
  SELECT DISTINCT COALESCE(f.company_name, s.source_company) AS company_name
  FROM (SELECT DISTINCT TRIM(company) AS source_company
        FROM `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`
        WHERE company IS NOT NULL) AS s
  LEFT JOIN `savvy-primacy-249323.taxi_curated.company_name_fix` AS f USING (source_company)
)
SELECT
  ROW_NUMBER() OVER (ORDER BY company_name)                   AS company_key,
  company_name,
  REGEXP_CONTAINS(company_name, r'^\d{4} - ')                 AS is_owner_operator,
  IF(REGEXP_CONTAINS(company_name, r'^\d{4} - '), 'Independent owner-operators', company_name) AS display_name
FROM names
UNION ALL
SELECT -1, 'Unmapped source name', FALSE, 'Unmapped source name';

CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.company_name_map` AS
SELECT s.source_company, c.company_key
FROM (SELECT DISTINCT TRIM(company) AS source_company
      FROM `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`
      WHERE company IS NOT NULL) AS s
LEFT JOIN `savvy-primacy-249323.taxi_curated.company_name_fix` AS f USING (source_company)
JOIN `savvy-primacy-249323.taxi_curated.dim_company` AS c
  ON c.company_name = COALESCE(f.company_name, s.source_company);

-- ---------------------------------------------------------------------------
-- 3. Seed: dim_community_area (77 Chicago community areas + 0 = unknown/outside)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.dim_community_area` AS
SELECT
  area_key,
  area_name,
  area_key = 76 AS is_ohare,
  area_key = 56 AS is_midway_area
FROM UNNEST([
  STRUCT(0 AS area_key, 'Unknown/outside' AS area_name),
  (1,'Rogers Park'),(2,'West Ridge'),(3,'Uptown'),(4,'Lincoln Square'),(5,'North Center'),
  (6,'Lake View'),(7,'Lincoln Park'),(8,'Near North Side'),(9,'Edison Park'),(10,'Norwood Park'),
  (11,'Jefferson Park'),(12,'Forest Glen'),(13,'North Park'),(14,'Albany Park'),(15,'Portage Park'),
  (16,'Irving Park'),(17,'Dunning'),(18,'Montclare'),(19,'Belmont Cragin'),(20,'Hermosa'),
  (21,'Avondale'),(22,'Logan Square'),(23,'Humboldt Park'),(24,'West Town'),(25,'Austin'),
  (26,'West Garfield Park'),(27,'East Garfield Park'),(28,'Near West Side'),(29,'North Lawndale'),(30,'South Lawndale'),
  (31,'Lower West Side'),(32,'Loop'),(33,'Near South Side'),(34,'Armour Square'),(35,'Douglas'),
  (36,'Oakland'),(37,'Fuller Park'),(38,'Grand Boulevard'),(39,'Kenwood'),(40,'Washington Park'),
  (41,'Hyde Park'),(42,'Woodlawn'),(43,'South Shore'),(44,'Chatham'),(45,'Avalon Park'),
  (46,'South Chicago'),(47,'Burnside'),(48,'Calumet Heights'),(49,'Roseland'),(50,'Pullman'),
  (51,'South Deering'),(52,'East Side'),(53,'West Pullman'),(54,'Riverdale'),(55,'Hegewisch'),
  (56,'Garfield Ridge'),(57,'Archer Heights'),(58,'Brighton Park'),(59,'McKinley Park'),(60,'Bridgeport'),
  (61,'New City'),(62,'West Elsdon'),(63,'Gage Park'),(64,'Clearing'),(65,'West Lawn'),
  (66,'Chicago Lawn'),(67,'West Englewood'),(68,'Englewood'),(69,'Greater Grand Crossing'),(70,'Ashburn'),
  (71,'Auburn Gresham'),(72,'Beverly'),(73,'Washington Heights'),(74,'Mount Greenwood'),(75,'Morgan Park'),
  (76,"O'Hare"),(77,'Edgewater')
]);


-- ---------------------------------------------------------------------------
-- 4. Seed: dim_payment_type (8 source values observed in the window + guard row)
--    tips_recorded: only card-type payments record tips (cash tips are not recorded).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.dim_payment_type` AS
SELECT * FROM UNNEST([
  STRUCT(-1 AS payment_type_key, 'Unmapped source value' AS payment_type, FALSE AS tips_recorded),
  (1, 'Credit Card', TRUE),
  (2, 'Mobile',      TRUE),
  (3, 'Prcard',      TRUE),
  (4, 'Cash',        FALSE),
  (5, 'Unknown',     FALSE),
  (6, 'No Charge',   FALSE),
  (7, 'Dispute',     FALSE),
  (8, 'Prepaid',     FALSE)
]);


-- ---------------------------------------------------------------------------
-- 5. Generated: dim_date (role: trip start date). date_key = yyyymmdd.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.dim_date` AS
SELECT
  CAST(FORMAT_DATE('%Y%m%d', d) AS INT64)  AS date_key,
  d                                         AS calendar_date,
  EXTRACT(YEAR FROM d)                      AS year,
  DATE_TRUNC(d, MONTH)                      AS month_start,
  (MOD(EXTRACT(DAYOFWEEK FROM d) + 5, 7) + 1)                AS weekday_num,   -- 1 = Monday ... 7 = Sunday
  FORMAT_DATE('%A', d)                      AS weekday_name,
  (MOD(EXTRACT(DAYOFWEEK FROM d) + 5, 7) + 1) IN (6, 7)      AS is_weekend
FROM UNNEST(GENERATE_DATE_ARRAY('2022-01-01', '2023-12-31')) AS d;


-- ---------------------------------------------------------------------------
-- 6. Generated: dim_time_of_day (96 x 15-minute slots; source times are rounded to 15 min)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.dim_time_of_day` AS
SELECT
  slot                                     AS time_key,
  TIME_ADD(TIME '00:00:00', INTERVAL slot * 15 MINUTE) AS slot_start,
  DIV(slot, 4)                             AS hour_of_day,
  CASE
    WHEN DIV(slot, 4) BETWEEN 5 AND 9   THEN 'Morning (05-09)'
    WHEN DIV(slot, 4) BETWEEN 10 AND 14 THEN 'Midday (10-14)'
    WHEN DIV(slot, 4) BETWEEN 15 AND 19 THEN 'Evening (15-19)'
    WHEN DIV(slot, 4) BETWEEN 20 AND 23 THEN 'Night (20-23)'
    ELSE 'Overnight (00-04)'
  END                                      AS daypart
FROM UNNEST(GENERATE_ARRAY(0, 95)) AS slot;


-- ---------------------------------------------------------------------------
-- 7. trip_clean (VIEW): typed, cleaned trip rows. No rows are removed.
--    - Times: the source TIMESTAMP holds Chicago wall-clock time with a UTC label
--      (P1 time-zone test). DATETIME(ts, 'UTC') keeps the stored clock value.
--      No AT TIME ZONE 'America/Chicago' conversion (that would shift every slot).
--    - Money: FLOAT64 -> NUMERIC rounded to cents.
--    - is_fare_valid: fare not null and 0 < fare <= 1000. Invalid fares stay as
--      trips but are left out of the average-fare measure.
--    - Null community area -> 0 (unknown/outside); the trip stays in market totals.
--    - company is TRIMmed (observed: 0 untrimmed values; kept as a guard).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW `savvy-primacy-249323.taxi_curated.trip_clean` AS
SELECT
  unique_key                                       AS trip_id,
  taxi_id,
  DATETIME(trip_start_timestamp, 'UTC')            AS trip_start_local,
  DATETIME(trip_end_timestamp, 'UTC')              AS trip_end_local,
  trip_seconds,
  trip_miles,
  COALESCE(pickup_community_area, 0)               AS pickup_area,
  COALESCE(dropoff_community_area, 0)              AS dropoff_area,
  ROUND(CAST(fare AS NUMERIC), 2)                  AS fare,
  fare IS NOT NULL AND fare > 0 AND fare <= 1000   AS is_fare_valid,
  ROUND(CAST(tips AS NUMERIC), 2)                  AS tips,
  ROUND(CAST(trip_total AS NUMERIC), 2)            AS trip_total,
  TRIM(payment_type)                               AS payment_type,
  TRIM(company)                                    AS company
FROM `savvy-primacy-249323.taxi_raw.taxi_trips_2022_2023`;


-- ---------------------------------------------------------------------------
-- 8. dim_taxi: one row per masked taxi_id.
--    current_company_key is Type 1 (company on the taxi's latest trip; ties at the
--    same 15-minute timestamp broken by trip_id so rebuilds are deterministic).
--    Roster use only. Trip attribution uses the company on each trip (fct_trip).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.dim_taxi` AS
WITH latest AS (
  SELECT
    taxi_id,
    ARRAY_AGG(company ORDER BY trip_start_local DESC, trip_id DESC LIMIT 1)[OFFSET(0)] AS latest_company,
    MIN(DATE(trip_start_local)) AS first_trip_date,
    MAX(DATE(trip_start_local)) AS last_trip_date
  FROM `savvy-primacy-249323.taxi_curated.trip_clean`
  GROUP BY taxi_id
)
SELECT
  ROW_NUMBER() OVER (ORDER BY l.taxi_id)  AS taxi_key,
  l.taxi_id,
  COALESCE(m.company_key, -1)             AS current_company_key,
  l.first_trip_date,
  l.last_trip_date
FROM latest AS l
LEFT JOIN `savvy-primacy-249323.taxi_curated.company_name_map` AS m
  ON m.source_company = l.latest_company;


-- ---------------------------------------------------------------------------
-- 9. fct_trip: transaction fact, one row per trip_id.
--    All joins are LEFT JOINs on unique dimension keys, so they cannot add or drop
--    trips. A source value with no dimension match gets key -1 (counted by check A).
--    company_key = company recorded on the trip itself (event-time attribution).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `savvy-primacy-249323.taxi_curated.fct_trip`
PARTITION BY DATE(trip_start_local)
CLUSTER BY company_key, pickup_area_key
OPTIONS (description = 'One row per distinct reported taxi trip (source unique_key), trip start 2022-01-01 to 2023-12-31 Chicago local time.')
AS
SELECT
  t.trip_id,
  CAST(FORMAT_DATE('%Y%m%d', DATE(t.trip_start_local)) AS INT64)                  AS date_key,
  EXTRACT(HOUR FROM t.trip_start_local) * 4 + DIV(EXTRACT(MINUTE FROM t.trip_start_local), 15) AS time_key,
  t.pickup_area                                    AS pickup_area_key,
  t.dropoff_area                                   AS dropoff_area_key,
  COALESCE(m.company_key, -1)                      AS company_key,
  COALESCE(x.taxi_key, -1)                         AS taxi_key,
  COALESCE(p.payment_type_key, -1)                 AS payment_type_key,
  t.trip_start_local,
  t.trip_end_local,
  1                                                AS trip_count,
  t.fare,
  t.is_fare_valid,
  t.tips,
  t.trip_total,
  t.trip_seconds,
  t.trip_miles
FROM `savvy-primacy-249323.taxi_curated.trip_clean` AS t
LEFT JOIN `savvy-primacy-249323.taxi_curated.company_name_map` AS m ON m.source_company = t.company
LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_taxi`         AS x ON x.taxi_id = t.taxi_id
LEFT JOIN `savvy-primacy-249323.taxi_curated.dim_payment_type` AS p ON p.payment_type = t.payment_type;


-- ---------------------------------------------------------------------------
-- 10. Build record (reads fct_trip only).
-- ---------------------------------------------------------------------------
SELECT
  COUNT(*)                     AS fct_rows,
  COUNTIF(is_fare_valid)       AS fare_valid_rows,
  COUNTIF(NOT is_fare_valid)   AS fare_invalid_rows,
  COUNTIF(pickup_area_key = 0) AS pickup_area_unknown,
  COUNT(DISTINCT company_key)  AS companies,
  COUNT(DISTINCT taxi_key)     AS taxis,
  (SELECT COUNT(*) FROM `savvy-primacy-249323.taxi_curated.company_name_map`) AS source_company_names,
  (SELECT COUNTIF(company_key > 0) FROM `savvy-primacy-249323.taxi_curated.dim_company`) AS dim_companies,
  (SELECT COUNTIF(is_owner_operator) FROM `savvy-primacy-249323.taxi_curated.dim_company`) AS owner_operators,
  COUNTIF(company_key IN (SELECT company_key FROM `savvy-primacy-249323.taxi_curated.dim_company`
                          WHERE is_owner_operator)) AS owner_operator_trips
FROM `savvy-primacy-249323.taxi_curated.fct_trip`;
