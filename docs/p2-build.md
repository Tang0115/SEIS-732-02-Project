# P2: Ingestion, Curation & Acceptance Checks

**Project:** Chicago Taxi Shift & Demand Planner
**Build run:** 2026-11-06, from execution project `savvy-primacy-249323`, processing location **US**.
**Status:** one complete source → Raw → Curated build, two acceptance checks passed.

**Code (run in this order)**
1. [`sql/02_ingest.sql`](../sql/02_ingest.sql): datasets and the source → Raw copy
2. [`sql/03_curate.sql`](../sql/03_curate.sql): seeds, dimensions, `trip_clean` view and `fct_trip`
3. [`sql/04_acceptance.sql`](../sql/04_acceptance.sql): check A, check B and a supporting company-total check

**Earlier work reused:** [P1 plan](p1-plan.md), [model diagram](model.svg), [`sql/01_source_profile.sql`](../sql/01_source_profile.sql). This repository holds code and aggregate results only, with no source rows.

**Review status.** P0 was approved with conditions (2026-10-16), and the P1 plan addresses those conditions (repeated keys, historical-baseline label, share of reported trips). P1 feedback had not been received as of 2026-11-06, so this build follows the submitted P1 plan (commit `2ee103b`). Any later "Revise before P2" item will be recorded here, along with the change it causes. These are the specific decisions I am bringing to the instructor while feedback is pending:

1. **Event-time company attribution instead of a Type 2 `dim_taxi`.** Each trip uses the company recorded on that trip. Is this an acceptable history treatment for P3?
2. **Name merges.** The four merges include Taxicab Insurance, which is now backed by the evidence in section 1. Does the instructor agree that a spelling change is Type 1 conformance, not a business change?
3. **Scope.** The window is 2022–2023 only, and the source is static. Is this bounded subset enough for the P3 rerun and changed-input demonstrations?

---

## 1. Establish the input and run ingestion

### Audience, question and what this path builds

- **Audience:** the operations manager of a mid-size Chicago taxi company ("Maria"), who schedules drivers and positions cabs each week.
- **Primary question (Q1):** for a selected company, compared with other companies, which hour-of-day × weekday × pickup community area slots had the most trips and the highest average fare per trip in 2022–2023?
- **What P2 builds:** the Raw copy and the full Curated star that Q1 reads: `fct_trip` and the date, time-of-day, community area, company, taxi and payment type dimensions. The same fact also serves the supporting question Q3 (monthly share of reported trips). The Serving aggregate `srv_demand_slot` and the dashboard are P3 work.

### Changes from P1

The source, window and grain are **unchanged**: one row per reported trip (`unique_key`) for trips starting 2022-01-01 to 2023-12-31. The implementation changes are small:

| Change | Reason |
|---|---|
| `trip_clean` is a **view**, not a table. | It only renames, types and flags Raw columns. A view keeps that logic visible and stores nothing twice. `fct_trip` is the materialized table. |
| Each dimension that maps a source string has a **guard row with key −1** (`dim_company`, `dim_payment_type`). | An unmatched source value then gets a visible key instead of a null, and check A counts it. Observed: 0 rows use it. |
| Display names repair two **truncated source strings**: "Medallion Leasin" → "Medallion Leasing" and "Patriot Taxi Dba Peace Taxi Associat" → "…Association". | This is a Type 1 display correction. The source string is still kept in `company_name_map`. |
| The model's `start_date_key` and `start_time_key` are named `date_key` and `time_key`. `dim_community_area` uses the area number itself as `area_key`. | Shorter names, same meaning. Trip start date is still the only date role. |
| The checks file is `sql/04_acceptance.sql` (P1 said `sql/03_checks.sql`). | It follows the P2 file layout. |
| The company mapping is **built from Raw** instead of a 42-row hand-written seed. Only 7 business-name conformance rules (`company_name_fix`) are written in the code. `company_key` is assigned by `ROW_NUMBER` over the conformed name. | 10 source names are owner-operator entries, and some contain a person's name. Writing them into a public repository would contradict the P1 access choice ("no person's name can reappear"). The names now stay inside BigQuery, where access is limited to the project owner. Because the source is static, the same Raw input gives the same keys. |
| **Taxicab Insurance merge confirmed** (P1's main open uncertainty). | See the evidence below. |

**Taxicab Insurance evidence.** P1 asked whether "Taxicab Insurance Agency Llc" and "Taxicab Insurance Agency, LLC" are one company. I checked this against Raw on 2026-11-06:

- 561 taxis used either name, and 104 of them used both.
- Of 7,227 taxi-months, only 89 show both names. Taxis do not split between the names, so this is not two fleets running side by side.
- The comma spelling falls every quarter (70,311 trips in 2022 Q1 down to 27,422 in 2023 Q4). The other spelling rises over the same period (13,807 up to 160,592).

The pattern is a gradual migration from one spelling to the other, and the names differ only by punctuation. **They stay merged** as company key 35. If they were kept apart, Q3 would show one company collapsing and another growing, which is an artefact of the spelling.

### Source and subset

| Item | Value |
|---|---|
| Source object | `bigquery-public-data.chicago_taxi_trips.taxi_trips` (project `bigquery-public-data`, dataset `chicago_taxi_trips`, table `taxi_trips`, US multi-region). Provider: City of Chicago Data Portal, "Taxi Trips (2013-2023)". |
| Subset | `trip_start_timestamp >= '2022-01-01' AND < '2024-01-01'` (all 23 columns) |
| Source state when read | 213,111,447 rows. Table `lastModifiedTime` was 2026-11-02 00:53 UTC. The row count is the same as in P0 and P1, and the latest trip is still 2023-12-31 23:45. |
| Build project / location | `savvy-primacy-249323`, US (matches the source location) |
| Datasets | `taxi_raw`, `taxi_curated`, `taxi_serving` (empty until P3) |

### Source → Raw step

[`sql/02_ingest.sql`](../sql/02_ingest.sql) section 2 runs one `CREATE OR REPLACE TABLE … AS SELECT` from the public table into `taxi_raw.taxi_trips_2022_2023`.

- **Preserved:** all 23 source columns, with names, types and values unchanged (`SELECT src.*`). No row is filtered except by the date window. Repeated keys, null areas and invalid fares all stay in Raw, so Curated rules can be checked against the original values.
- **Added:** two load columns. `_source_table` holds the full source identifier, and `_loaded_at` holds the load time.
- **Storage:** the table is partitioned by `DATE(trip_start_timestamp)` (730 partitions) and clustered by `company` and `pickup_community_area`. Later steps read this copy instead of the public table.
- **Load behaviour:** the step **replaces** the table, with no append. The source is unpartitioned, so the date filter does not reduce the bytes read. The dry run estimated 82.99 GB, the job billed **83.74 GB**, and it ran under a 90 GB `--maximum_bytes_billed` cap.

### Load record (section 3 of `02_ingest.sql`)

| Measure | Observed |
|---|---|
| Loaded (`_loaded_at`) | 2026-11-06 16:45:25 UTC |
| Raw rows | **12,877,486** (2022: 6,382,071; 2023: 6,495,415) |
| Distinct `unique_key` / null keys | 12,877,486 / 0 |
| Start range | 2022-01-01 00:00 to 2023-12-31 23:45 |
| Stored size | 5.84 GB |

These counts match the P1 window counts exactly.

**One Raw row** = one source row = one trip reported to the City, for a trip starting in the window.

**Reproducibility.** The source is static: it has had no trips after 2023-12-31 since P0. Rerunning the step with the same window should therefore return the same 12,877,486 rows, and only `_loaded_at` changes. The remaining limit is that the public table has no version or snapshot ID I can pin. The City or Google could republish it, and BigQuery time travel on a public table cannot be relied on. The source row count, the window counts and the distinct-key count above act as a fingerprint. A rerun that does not reproduce them means the source changed. From this point on, the Raw copy in my project is the fixed input for P3.

---

## 2. Build Curated at the intended grain

### Objects ([`sql/03_curate.sql`](../sql/03_curate.sql))

| Object | Type | Rows | One row is |
|---|---|---|---|
| `company_name_fix` | seed table | 7 | one business-name conformance rule (merge or truncation repair) |
| `dim_company` | built from Raw + `company_name_fix` | 39 | one conformed company (38) plus guard row −1 |
| `company_name_map` | built from Raw + `dim_company` | 42 | one source company spelling → `company_key` |
| `dim_community_area` | seed table | 78 | one community area (1–77) plus 0 = unknown/outside |
| `dim_payment_type` | seed table | 9 | one source payment type (8) plus guard row −1 |
| `dim_date` | generated | 730 | one calendar date (trip start date role) |
| `dim_time_of_day` | generated | 96 | one 15-minute slot |
| `trip_clean` | view over Raw | 12,877,486 | one Raw trip, typed and flagged |
| `dim_taxi` | table | 3,689 | one masked `taxi_id` |
| **`fct_trip`** | table, partitioned by trip start date, clustered by `company_key`, `pickup_area_key` | **12,877,486** | **one distinct reported trip** |

**Curated grain:** one `fct_trip` row is one distinct reported taxi trip that starts between 2022-01-01 00:00 and 2023-12-31 23:45 Chicago local time. The row is **identified by `trip_id`**, which is the source `unique_key`. Uniqueness is backed by the evidence in check A, not assumed.

### Rules and the evidence for them

| Field(s) | Rule | Evidence and why it matters for Q1 |
|---|---|---|
| `unique_key` → `trip_id` | Retained as the fact key, with **no dedupe step**. | Raw has 0 null and 0 repeated keys in the window (load record). Adding a dedupe rule would be a transformation with no observed purpose. The repeated keys exist only in 2013 and 2019 (P1). |
| `trip_start_timestamp` → `trip_start_local` | `DATETIME(ts, 'UTC')` keeps the stored clock value. **No** `America/Chicago` conversion. | The stored values are Chicago wall-clock time with a UTC label (P1: 0 trips at 02:xx on spring-forward days, peak at 17:00). Check B tests this again on the built fact. A conversion would move every Q1 slot by 5–6 hours. |
| `date_key`, `time_key` | Derived from `trip_start_local`: `yyyymmdd` and `hour*4 + minute/15`. | All Raw start times are on a 15-minute boundary (0 exceptions), so 96 slots cover every trip. |
| `pickup_community_area`, `dropoff_community_area` | A null area becomes key 0, "Unknown/outside". The row is **kept**. | 755,383 pickups (5.87%) are null. Dropping them would understate market demand. Key 0 lets them stay in totals and be shown separately. No area falls outside 1–77. |
| `fare` | `ROUND(CAST(fare AS NUMERIC), 2)`. `is_fare_valid = fare IS NOT NULL AND 0 < fare ≤ 1000`. | 0 Raw fares have more than 2 decimals, so the cast changes no value. 27,809 trips are not fare-valid: 15,673 null, 11,519 at or below 0, and 617 above $1,000. They still count as trips but are excluded from average fare. |
| `company` → `company_key` | `TRIM` the name, apply the 7 `company_name_fix` rules, and look the result up in `company_name_map` (42 names → 38 companies). Event-time: each trip uses the company recorded **on that trip**. Owner-operator entries (`^\d{4} - `) get `is_owner_operator = TRUE` and the `display_name` "Independent owner-operators". | 0 null companies and 0 untrimmed names in the window. The map is built from the same Raw names, so 0 trips on key −1 is expected by construction. The real test is the 38-company count and the P1 company totals in R3. Owner-operators: 10 companies, 21,775 trips, the same as P1. The merge rule and the event-time choice come from P1 Task 2. |
| `taxi_id` → `taxi_key`, `dim_taxi.current_company_key` | Surrogate key. The current company is the company on the taxi's latest trip (Type 1), with ties broken by `trip_id`. | Used for a roster view only, never for attributing trips. The tie-break makes rebuilds deterministic, which fixes the P1 note that ties were "broken arbitrarily". |
| `payment_type` → `payment_type_key` | Lookup against 8 observed values. `tips_recorded` is TRUE for Credit Card, Mobile and Prcard. | All 8 Raw values match. Cash tips are not recorded (P0). |

**Joins.** `fct_trip` uses three `LEFT JOIN`s, to `company_name_map`, `dim_taxi` and `dim_payment_type`. Each joins on a key that is unique in the right-hand table, so a join cannot add or remove trips.

### Row counts: Raw vs Curated

| Object | Rows |
|---|---|
| Raw `taxi_trips_2022_2023` | 12,877,486 |
| Curated `fct_trip` | 12,877,486 |
| of which fare-valid | 12,849,677 |
| of which pickup area 0 | 755,383 |

The counts are equal, with **no material difference**, because no Curated rule removes rows. Invalid fares and unknown areas are flagged or keyed and stay in the fact. Check A confirms the match trip by trip, not only by total.

### Field trace: `fare` → average fare per trip

| Step | Object.field | Rule | Observed (2026-11-06) |
|---|---|---|---|
| Source | `bigquery-public-data.chicago_taxi_trips.taxi_trips.fare` (FLOAT64, USD) | none | read by the Raw CTAS |
| Raw | `taxi_raw.taxi_trips_2022_2023.fare` (FLOAT64) | copied unchanged | 12,877,486 rows; 15,673 null; 0 with more than 2 decimals |
| Curated | `taxi_curated.trip_clean.fare` / `.is_fare_valid` → `fct_trip.fare` (NUMERIC), `fct_trip.is_fare_valid` | `ROUND(CAST(fare AS NUMERIC),2)`; valid when 0 < fare ≤ 1000 | 12,849,677 valid trips; sum of valid fares $280,318,836.72; market average **$21.8152**, the same as an independent Raw computation (check B). Example cell: O'Hare pickups, Friday, hour 17 = 22,077 trips, 22,033 fare-valid, average $41.04. |
| Serving (**planned, P3**) | `taxi_serving.srv_demand_slot.fare_sum`, `.fare_valid_trips` | `SUM(IF(is_fare_valid, fare, 0))`, `COUNTIF(is_fare_valid)` by company × year × weekday × hour × pickup area | not built |
| Audience (**planned, P3**) | Looker Studio "Average fare per trip" | `SUM(fare_sum) / SUM(fare_valid_trips)` after filters; hidden below 30 fare-valid trips | not built |

---

## 3. Run and interpret two acceptance checks

Both checks are in [`sql/04_acceptance.sql`](../sql/04_acceptance.sql). They ran on 2026-11-06 against the built objects, and each returns a PASS/FAIL column.

| Risk and affected result | Check code | Expected result and why | Observed result | Interpretation or action |
|---|---|---|---|---|
| **A. Grain and relationships (P1 R1).** The fact joins could add, drop or duplicate trips, or leave keys with no dimension row. Q1 trip counts would then be inflated or missing. | `sql/04_acceptance.sql`, CHECK A. It inspects `fct_trip` **after** the joins, anti-joins it to Raw in both directions, and anti-joins each of the 7 foreign keys to its dimension. | `fct_rows` = `fct_distinct_trip_id` = `raw_rows` = 12,877,486, so the key is still unique after the joins and no trip was lost. Raw trips missing from fct = 0 and fct trips not in Raw = 0 show it is the *same* set of trips, not only the same count. 0 null keys, 0 orphan keys and 0 guard (−1) keys mean every trip can be filtered and grouped. | 12,877,486 = 12,877,486 = 12,877,486. Missing 0, extra 0. Null keys 0. Orphans 0 for all 7 keys. Guard keys 0. **PASS** | The Curated fact keeps the intended grain, and every relationship Q1 needs (time, date, pickup area, company) resolves. No action needed. A new company spelling in a future load would show up here as guard-key rows, not as silently missing trips. |
| **B. Meaning of a Q1 cell (P1 R2a/R2b).** A time-zone shift, a wrong weekday or unknown-area rule, or a changed fare rule would make an hour × weekday × pickup-area cell show the wrong trips or a wrong average fare. | `sql/04_acceptance.sql`, CHECK B. Every market cell is computed from the Curated star (fact + `dim_time_of_day` + `dim_date` + `dim_community_area`) and **independently** from Raw (`EXTRACT` on the stored timestamp, `FORMAT_DATE` weekday, null-area test, fare rule on FLOAT64), then compared with a full outer join. The P1 time-zone markers are also read from the fact. | 0 cells on one side only, 0 trip-count mismatches, 0 fare-valid mismatches, fare sums equal to within half a cent. Both sides apply the documented rules separately, so agreement shows the Curated keys and flags carry the intended meaning. The peak hour should be 17 with 921,860 trips, and there should be 0 trips at 02:xx on 2023-03-12. These are the P1 wall-clock results, and they would fail under a conversion. | 13,027 cells compared. One-side-only 0, trip mismatches 0, fare-valid mismatches 0. Largest fare-sum difference 5.8 × 10⁻¹⁰ (float rounding). Average fare $21.8152 on both sides. Peak hour 17 = 921,860. 02:xx on 2023-03-12 = 0. **PASS** | Q1 cells in Curated mean what the dashboard will say. **Negative control:** applying the `America/Chicago` conversion to Raw moves the peak hour to 12 (906,109 trips), so this check would have failed with a conversion. No action needed. |

**Supporting result (not one of the two required checks): P1 R3, company attribution.** The third query reproduces the P1 expected values, which P1 computed directly from the public source:

| Measure | P1 expected | Curated observed |
|---|---|---|
| 5 Star Taxi 2022 / 2023 | 157,880 / 299,448 | 157,880 / 299,448 |
| Blue Ribbon (merged) 2022 / 2023 | 189,022 / 205,906 | 189,022 / 205,906 |
| All trips 2022 / 2023 | 6,382,071 / 6,495,415 | 6,382,071 / 6,495,415 |
| Companies | 38 | 38 |

**Problems found and fixed during the build.** None of these were data problems:

1. The `O'Hare` literal used SQL-style `''` escaping, which BigQuery rejects. It was changed to a double-quoted string.
2. `ISOWEEKDAY` is not a valid BigQuery date part. It was replaced with `MOD(DAYOFWEEK + 5, 7) + 1` (1 = Monday). The weekday names come from `FORMAT_DATE('%A')`, and check B confirms that they match Raw.
3. The first run of check B failed on a cast of the text `'unknown'` to INT64. The Raw side now joins on the integer area directly.

All results above come from the final runs.

**Unresolved issues.** There are no unresolved data issues for this path. Small-cell averages (P1 R2c) are a Serving risk and will be measured in P3.

---

## 4. Make the run reproducible and record the next step

### Run order

**Prerequisites:**
- A Google Cloud project you own with BigQuery enabled and billing or free tier available. Mine is `savvy-primacy-249323`. Replace the project ID in the three files if yours differs.
- Read access to `bigquery-public-data`.
- The `bq` CLI, authenticated (`gcloud auth login`).

I run every command with `CLOUDSDK_ACTIVE_CONFIG_NAME=seis732` so my default gcloud account is unaffected.

| # | Step | Command / code | Needs to exist first | Changes | Inspect |
|---|---|---|---|---|---|
| 1 | Dry-run the Raw load | `bq query --use_legacy_sql=false --dry_run` on the CTAS `SELECT` in [`02_ingest.sql`](../sql/02_ingest.sql) | source access | nothing | about 83 GB to be read |
| 2 | Create datasets and Raw | `bq query --use_legacy_sql=false --maximum_bytes_billed=90000000000 < sql/02_ingest.sql` | step 1 | creates the 3 datasets if missing; **replaces** `taxi_raw.taxi_trips_2022_2023` | load record: 12,877,486 rows, 0 null and 0 repeated keys |
| 3 | Build Curated | `bq query --use_legacy_sql=false --maximum_bytes_billed=10000000000 < sql/03_curate.sql` | Raw table | **replaces** all 9 Curated tables and the `trip_clean` view (about 6.4 GB billed) | build record: 12,877,486 fact rows, 12,849,677 fare-valid, 755,383 area 0, 38 companies from 42 source names, 10 owner-operators (21,775 trips), 3,689 taxis |
| 4 | Acceptance checks | `bq query --use_legacy_sql=false --maximum_bytes_billed=10000000000 < sql/04_acceptance.sql` | step 3 | nothing (read-only) | A = PASS, B = PASS, R3 values as in section 3 (about 1.1 GB billed) |

Inside `03_curate.sql`, the order matters: `company_name_fix` first, then `dim_company` and `company_name_map`, which read Raw and the fix table. The other seeds and generated dimensions come next, then `trip_clean`, then `dim_taxi`, which reads `trip_clean`, and last `fct_trip`, which reads all of them.

**Save before overwrite.** Steps 2 and 3 use `CREATE OR REPLACE`. A rerun overwrites the current Raw and Curated tables and the old `_loaded_at`. The results that P3 will compare against are recorded in this note: the load record, build record, check results and R3 company totals. Before the P3 changed-input demonstration, I will snapshot `fct_trip` (for example with `CREATE SNAPSHOT TABLE`) so the "before" state still exists.

**Check of these instructions against the build.** Steps 2–4 above are the exact commands I ran on 2026-11-06, and the outputs recorded here are from those runs. After I replaced the hand-written company seed with the Raw-derived mapping, I reran steps 3 and 4. Check A, check B and the R3 totals returned the same results. Total P2 cost was about 104 GB billed: 83.7 GB for the Raw load and the rest for profiling, the Curated build and checks. This is within the 1 TB monthly free query tier. Storage is 5.84 GB for Raw and 2.41 GB for `fct_trip`.

### Model update

The meaning of [`model.svg`](model.svg) is unchanged. The implementation differences are the ones listed in the "Changes from P1" table: renamed date and time keys, `area_key` equal to the area number, guard rows −1, and `trip_clean` built as a view. I left the diagram as it is.

### Main limitation of this P2 path

The fact has no Serving layer yet, so the **small-cell risk is not yet measured**. In the company view, an hour × weekday × pickup-area cell can hold very few trips. For example, 5 Star Taxi had 157,880 trips in 2022, spread over up to 13,104 cells. Until `srv_demand_slot` exists and R2c runs, I cannot say whether the 30-trip threshold leaves a usable heat map or whether hours must be coarsened to dayparts. The broader product limitation is unchanged: the data covers reported taxi trips only and ends 2023-12-31, so the product is a historical planning baseline.

### Next concrete P3 build step

1. Build `taxi_serving.srv_demand_slot` (company × year × weekday × hour × pickup area: `trips`, `fare_sum`, `fare_valid_trips`) and `srv_company_share_month` from `fct_trip`.
2. Run R2b (Serving totals reconcile to `fct_trip`: 12,877,486 trips, 12,849,677 fare-valid, average $21.8152).
3. Run R2c (share of 5 Star Taxi and market trips in cells below 30 fare-valid trips).
4. Then do the same-input rerun and the changed-input case: one taxi moves from 5 Star Taxi to Flash Cab, and 5 Star Taxi 2022 must stay 157,880.

### AI / tool accountability

- **Claude Code (Anthropic)** did the following:
  - drafted `02_ingest.sql`, `03_curate.sql`, `04_acceptance.sql` and this note;
  - ran the profiling, the build and the checks through the `bq` CLI in my project, with dry runs and byte caps;
  - typed the 77 community area names into the seed from general knowledge;
  - proposed the Taxicab Insurance overlap test and the time-zone negative control.
- **How I checked it:**
  - Every number in this note comes from a query run on 2026-11-06. The query IDs are in `INFORMATION_SCHEMA.JOBS` for the project.
  - The Raw and Curated counts reconcile with the P1 results, which were computed separately from the public source (12,877,486 trips; year totals; 755,383 null pickups; 5 Star Taxi and Blue Ribbon totals).
  - Check B recomputes Q1 cells from Raw without using the Curated keys, and the negative control shows that the check can fail.
  - The area names for 32 (Loop), 56 (Garfield Ridge), 76 (O'Hare) and 77 (Edgewater) match P0/P1. **Before P4 I still need to verify the full 77-name list against the City's community-area list.**
- **Access:** no owner-operator name is written in this repository. Those names exist only in `taxi_raw` and `taxi_curated` in my project, and anything built for the audience uses `display_name`.
- **Responsibility:** the rules are mine and I can explain each one. They are: keeping the key without a dedupe step, no time-zone conversion, key 0 for unknown areas, the fare-validity range, the Taxicab Insurance merge, and event-time company attribution.
