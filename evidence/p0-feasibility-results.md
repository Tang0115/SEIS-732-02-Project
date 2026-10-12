# P0 Feasibility Results — Chicago Taxi Trips

Summarized output of `sql/00_feasibility.sql`. Only schema facts, counts, ranges, and my interpretation are recorded here. No source rows are included.

- **Run date:** 2026-10-12
- **Execution project:** my own SEIS 732 project (`savvy-primacy-249323`), location US
- **Source object:** `bigquery-public-data.chicago_taxi_trips.taxi_trips`
- **Bytes processed:** about 91 GB across all queries. Each query was dry-run first, and a per-query `maximum_bytes_billed` cap was set.

## Objects and physical design (queries 1–3)

| Fact | Value |
|---|---|
| Objects in dataset | 1 base table: `taxi_trips` (created 2017-04-12) |
| Location | US multi-region |
| Row count (metadata) | 213,111,447 |
| Logical size | 77.29 GiB (~83 GB) |
| Partitioning / clustering | None / none |
| Last modified (metadata) | 2026-10-11 22:08 UTC |
| Columns | 23 (2 STRING ids, 2 TIMESTAMP, 9 FLOAT64 money/geo, 5 INT64, 5 STRING descriptors/locations) |

**Interpretation:** a date filter does not reduce cost on this table, because it has no partitioning. Any column scanned is read in full. The key check (query 4: `unique_key`, `taxi_id`, start timestamp) processed about 38 GB. In P1 I should build a smaller curated copy (partitioned by trip date) in my own project rather than query the source repeatedly.

## Coverage and keys (query 4)

| Fact | Value |
|---|---|
| Earliest `trip_start_timestamp` | 2013-01-01 00:00 |
| Latest `trip_start_timestamp` | 2023-12-31 23:45 |
| `unique_key` nulls | 0 |
| `unique_key` distinct | 211,655,459 |
| Rows minus distinct keys | **1,455,988 (0.68%)**, so `unique_key` is **not unique** |
| `taxi_id` nulls / distinct | 0 / 9,805 |

**Interpretation:** the metadata timestamp is recent, but the trip data **stops at 2023-12-31**. The City of Chicago portal page for this source is titled "Taxi Trips (2013-2023)". It states that the dataset ends with 2023 and that later trips are in a separate dataset. I will treat the BigQuery source as **static**.

`unique_key` is described as a trip identifier, but about 1.46M rows repeat a key. I have not yet checked whether those are exact duplicate rows or different trips sharing a key. That check is the first P1 decision.

## Null rates, full table (query 5)

| Column | Null share |
|---|---|
| `company` | 15.76% |
| `dropoff_community_area` | 13.49% |
| `pickup_community_area` | 11.39% |
| `trip_seconds` | 0.61% |
| `trip_end_timestamp`, `fare`, `tips`, `trip_total` | 0.01% each |
| `trip_miles`, `payment_type` | ~0% |

**Interpretation:** the money and time fields are nearly complete. Community area is missing on 11–13% of rows. Per the column descriptions, many of these are trips outside Chicago or rows suppressed for privacy. `company` is missing on about 16% of rows overall, which matters for the company-share question. I have not yet broken the company null rate down by year.

## Volume by year (query 6)

| Year | Trips | Distinct company names |
|---|---|---|
| 2013 | 27,223,578 | 37 |
| 2014 | 37,395,079 | 106 |
| 2015 | 32,385,527 | 67 |
| 2016 | 31,756,403 | 89 |
| 2017 | 24,979,611 | 85 |
| 2018 | 20,731,105 | 73 |
| 2019 | 17,926,150 | 58 |
| 2020 | 3,888,831 | 52 |
| 2021 | 3,947,677 | 40 |
| 2022 | 6,382,071 | 37 |
| 2023 | 6,495,415 | 36 |

**Interpretation:** there are no missing years. Volume drops sharply in 2020 (pandemic) and has only partly recovered. The 2014–2016 company-name counts look inflated, which suggests inconsistent spellings. **Recommended analysis window: 2022–2023**, about 12.9M trips with a stable set of companies.

## Timestamp granularity, 2023 (query 7)

All 6,495,415 trips in 2023 start at minute 0, 15, 30 or 45, with near-equal counts. This confirms the documented rounding to 15 minutes. Hour-of-day and day-of-week analysis is supported; analysis finer than 15 minutes is not.

## Company field, 2023 (query 8)

- 36 distinct company names in 2023.
- The top 10 names (approximate counts) account for about 5.84M of 6.50M trips, roughly 90%. Leaders: Flash Cab (~1.26M), Taxi Affiliation Services (~1.24M), Sun Taxi (~0.72M), City Service (~0.65M).
- At least one name appears truncated ("Medallion Leasin"), so the names need a cleanup and mapping step.

## Payment types and implausible values, 2023 (query 9)

| Payment type | Trips | Avg tip ($) |
|---|---|---|
| Credit Card | 2,646,588 | 6.05 |
| Cash | 1,948,271 | 0.02 |
| Mobile | 958,183 | 3.25 |
| Prcard | 647,174 | 0.22 |
| Unknown | 290,764 | 0.00 |
| No Charge | 2,556 | 0.27 |
| Dispute | 1,879 | 0.02 |

- Fare ≤ 0: 5,373 trips. `trip_seconds` ≤ 0: 128,049 trips (about 2.0%; 96,014 of them are Cash). `trip_total` > $1,000: 201 trips.
- **Interpretation:** the column description says *"Cash tips generally will not be recorded."* The near-zero cash average confirms this. Tip analysis must be limited to card and mobile payments, or labeled as "recorded tips", or it will mislead. Zero-duration and extreme-total rows need exclusion rules in P1.

## Airport vs. other trips, 2023 (query 10)

| Group | Trips | Avg fare ($) | Avg recorded tip ($) | Avg minutes |
|---|---|---|---|---|
| O'Hare (area 76, pickup or dropoff) | 1,596,338 (24.6%) | 40.32 | 6.80 | 35.1 |
| Midway area (area 56) | 303,482 (4.7%) | 33.57 | 5.38 | 29.2 |
| Other | 4,595,595 (70.8%) | 15.23 | 1.49 | 15.2 |

**Interpretation:** the community-area fields support the airport question. Community area 76 maps cleanly to O'Hare. Area 56 (Garfield Ridge) contains Midway but also residential blocks, so "Midway" is an approximation. Census tract or pickup coordinates could refine it, where they are not suppressed.

## Overall verdict

The source is accessible from my execution project, large enough, and has the time, place, money, payment and company fields that all four questions need. The main issues to resolve are the duplicated `unique_key` rows, cash-tip under-recording, company-name cleanup and nulls, and the data ending in 2023. Each is bounded and can be handled in P1.
