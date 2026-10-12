# P0 — Need, Audience, Dataset & Feasibility

Supporting evidence: [`sql/00_feasibility.sql`](../sql/00_feasibility.sql) (queries) and [`evidence/p0-feasibility-results.md`](../evidence/p0-feasibility-results.md) (summarized results).

## 1. Working title

**Chicago Taxi Shift & Demand Planner**

## 2. Audience and need

**Audience.** The operations manager of a mid-size Chicago taxi company, one of the roughly 36 companies that report trips to the City. (Scenario: "Maria" runs dispatch and driver scheduling for her fleet.)

**Decision or recurring task.** Each week Maria decides:
- how many drivers to schedule for each shift (hour and weekday);
- where to position cabs at the start of a shift (downtown, neighborhoods, or the airports).

**Problem today.** These decisions rest on habit and driver anecdotes. Over-staffing slow periods wastes driver time and lease costs. Under-staffing busy periods hands fares to competing companies and rideshare.

**Why a data product helps.** The City's trip records show when and where demand and revenue actually occur across the whole market. They also show how her company's share compares with competitors'. A dashboard turns about 6.5M trips per year into a weekly planning view.

**What she might do differently.** Shift driver hours toward high-revenue windows, send more cabs to O'Hare when airport trips outperform city trips, and track whether her market share responds.

## 3. Proposed analytical product and questions

**Product.** An interactive dashboard (Looker Studio on top of curated BigQuery tables). It shows trip volume and revenue by hour, weekday and community area, with a company filter so Maria can compare her fleet with the whole market.

**Questions.**
1. **When and where is demand highest?** Which hour-of-day × weekday slots and pickup community areas have the most trips and the highest average revenue per trip?
2. **Are airport trips worth it?** How do O'Hare and Midway-area trips compare with other trips on average fare, recorded tip, and trip duration?
3. **Are we gaining or losing ground?** How has a selected company's monthly share of trips and revenue changed from 2022 through 2023?
4. **Where do recorded tips come from?** How do recorded tip rates (tip ÷ fare) differ by payment type, area and time, limited to payment types where tips are recorded?

## 4. Source identification and access

| Item | Value |
|---|---|
| Source dataset / provider | Chicago Taxi Trips, provided by the **City of Chicago** (Data Portal dataset "Taxi Trips (2013-2023)"), hosted as a Google BigQuery public dataset |
| Source URLs | City portal: https://data.cityofchicago.org/Transportation/Taxi-Trips/wrvz-psew · Google Cloud listing: https://console.cloud.google.com/marketplace/product/city-of-chicago-public-data/chicago-taxi-trips |
| BigQuery project.dataset | `bigquery-public-data.chicago_taxi_trips` |
| Candidate object(s) and location | `taxi_trips` (base table; the only object in the dataset), US multi-region |
| Access | Confirmed 2026-10-12. I queried the table from my own execution project `savvy-primacy-249323` (the course setup model, same project as A00). It is a free public dataset; my project pays only query processing. No paid listing. |
| Use / attribution constraints | The City portal lists attribution "City of Chicago" and license "See Terms of Use". I will credit the City of Chicago Data Portal in the dashboard and README. I will not redistribute row-level extracts. The City notes that taxi IDs are masked, census tracts are sometimes suppressed for privacy, times are rounded to 15 minutes, and "not all trips are reported". |

## 5. Quick source profile

Full results are in [`evidence/p0-feasibility-results.md`](../evidence/p0-feasibility-results.md).

- **One row:** one reported taxi trip, with start/end time, duration, distance, pickup/dropoff area, fare components, payment type, company and masked taxi ID.
- **Row count:** 213,111,447 (77.29 GiB). No partitioning or clustering.
- **Time coverage:** 2013-01-01 to 2023-12-31. Every year is present. Volume drops from 17.9M (2019) to 3.9M (2020), then 6.5M in 2023. The table's metadata was modified 2026-10-11, but no trips after 2023 exist, so the source is **static**.
- **IDs / keys:**
  - `unique_key` (trip): 0 nulls, but 211,655,459 distinct values for 213,111,447 rows, so **1,455,988 rows (0.68%) repeat a key**.
  - `taxi_id` (masked vehicle/medallion): 0 nulls, 9,805 distinct.
  - `company`: name string, 36 distinct names in 2023.
- **Fields supporting the questions:**
  - time: `trip_start_timestamp`, `trip_seconds`
  - place: `pickup_community_area`, `dropoff_community_area`
  - money: `fare`, `tips`, `trip_total`
  - descriptors: `payment_type`, `company`
- **Null / quality issues:**
  - `company` 15.8% null overall.
  - Pickup and dropoff community area 11.4% / 13.5% null.
  - Money fields about 0.01% null.
  - 2023 only: 128,049 trips with `trip_seconds` ≤ 0, 5,373 with fare ≤ 0, and 201 with total > $1,000.
  - Some company names are inconsistent or truncated, e.g. 106 names in 2014 and a truncated "Medallion Leasin".
- **Types:** all scalar columns, nothing nested. The location columns are WKT-style strings duplicating the latitude/longitude columns.
- **Refresh:** none for trip content after 2023. The City publishes 2024+ trips as a separate portal dataset, which is not part of this BigQuery source.
- **Sensitivity and interpretation:**
  - No personal data, and taxi IDs are masked.
  - **Cash tips are generally not recorded** (2023 average cash tip $0.02 vs. $6.05 for credit card), so tip metrics must be labeled "recorded tips" and limited by payment type.
  - Times are rounded to 15 minutes, so the finest supported time grain is 15 minutes.
  - I will not show individual-taxi results.

## 6. Need-to-source fit

| Proposed question | Needed fields or concepts | Candidate source object(s) | Why the source appears sufficient | Gap or assumption to test in P1 |
|---|---|---|---|---|
| Q1 Demand by time and place | trip count, start hour/weekday, pickup area, `trip_total` | `taxi_trips` | Start time is 100% populated at 15-minute grain; pickup area is ~89% populated; 2023 alone has 6.5M trips | Treatment of null pickup areas (show as "outside/unknown"?); exclusion rules for zero-duration or extreme-total trips; dedupe of repeated `unique_key` |
| Q2 Airport vs. other trips | pickup/dropoff community area, `fare`, `tips`, `trip_seconds` | `taxi_trips` | 2023 O'Hare (area 76) trips: 1.6M, avg fare $40.32 vs. $15.23 for other trips | Area 56 (Garfield Ridge) covers more than Midway; test census tract or coordinates as a tighter airport flag |
| Q3 Company share over time | `company`, trip month, `trip_total` | `taxi_trips` | 36 company names in 2023; top 10 ≈ 90% of trips; monthly grain available | Company null rate by year; name cleanup/mapping; whether share is meaningful when not all trips are reported |
| Q4 Recorded tip patterns | `tips`, `fare`, `payment_type`, area, time | `taxi_trips` | Card and mobile trips (~3.6M in 2023) carry recorded tips | Cash tips are not recorded, so the analysis is limited to card/mobile payments and labeled as recorded tips; confirm meaning of "Prcard" |

## 7. Feasibility risks and response

1. **Duplicate trip keys.** Evidence: 1,455,988 rows share a `unique_key`. Not yet known whether they are exact duplicates. Response: in P1, profile the duplicated keys (exact-row duplicates vs. conflicting values, which years), then set a dedupe rule before choosing the fact grain.
2. **Query cost on an unpartitioned 77 GiB table.** Evidence: P0 checks processed about 91 GB; the key check alone processed about 38 GB. Response: build one curated, date-partitioned copy limited to 2022–2023 and the needed columns in my own project. All later work reads that copy, not the source. Keep dry-runs and `maximum_bytes_billed` caps on every query.
3. **Misleading metrics: tips, company names, static end date.** Evidence: cash tips are about $0; 15.8% of rows have a null company; names are inconsistent; data ends 2023-12-31. Response: label tips as "recorded tips (card/mobile)", build a company-name mapping, show null company as "Unknown", and present the product as a historical planning baseline (2022–2023), not live operations. A later change case can come from the course's bounded delta.

**Fallback.** If company share (Q3) proves unreliable because of nulls or naming, drop the company comparison. Keep a market-wide demand planner (Q1, Q2, Q4) for any Chicago fleet. This uses the same source and the same fact grain.

## 8. First P1 decision

**Define the fact grain and dedupe rule for `unique_key`.** Is one row of the fact table one distinct trip? If so, how are the 1.46M repeated-key rows resolved (drop exact duplicates, keep latest, or exclude conflicts)? The same decision fixes the analysis window (2022–2023) and the exclusion rules for zero-duration and extreme-value trips.

## 9. AI/tool accountability

- **Claude Code (Anthropic) assistant:**
  - helped set up the repository structure and a separate gcloud configuration for my course project;
  - read the Canvas setup and A00 pages to identify the correct execution project;
  - drafted the profiling queries and these documents.
- **Verification:**
  - Every number in this document comes from queries in `sql/00_feasibility.sql` that I ran in my own project on 2026-10-12, or from BigQuery table metadata (`bq show`).
  - The "Taxi Trips (2013-2023)" title, attribution and data-end note come from the City of Chicago portal's own dataset metadata.
  - Field meanings (rounded times, unrecorded cash tips, privacy suppression) come from the BigQuery column descriptions.
  - The audience scenario and questions are my own framing. I reviewed the AI-drafted wording and can explain each claim.
