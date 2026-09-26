# Analysing battery_insights data in BigQuery

How to turn `battery_segment`, `battery_flow` and `battery_session` events from **Firebase Analytics** into numbers you can trust. Replace `PROJECT` with your GCP project and `analytics_XXXX` with your Firebase export dataset (`analytics_<property id>`).

Using another backend? The metric rules in [§3](#3-metrics--how-to-aggregate-correctly) apply unchanged.

## 1. What lands in BigQuery

Firebase writes one row per event to `analytics_XXXX.events_YYYYMMDD` (daily, finalised) and, with streaming export, `events_intraday_YYYYMMDD`. Each row carries:

- `event_params` — the event's fields. Strings in `value.string_value`, integers in `value.int_value`, decimals in `value.double_value`.
- `user_properties` — `battery_capacity_mah`, `battery_design_mah`, `battery_cycle_count`, `battery_health` (as strings), if you route `deviceSink` to user properties.
- `device.mobile_brand_name`, `device.mobile_model_name`, `device.operating_system_version`, `app_info.version`, `user_pseudo_id` (one per install).

Two things to know:

- **Late events.** Phones upload in batches; Firebase keeps updating a day's table for up to 72 hours. The curated table below re-processes the last three days on every run.
- **Wildcard suffixes.** `events_*` also matches `events_intraday_*`. A `_TABLE_SUFFIX BETWEEN '2026…' AND '2026…'` filter excludes intraday (its suffix starts with `i`).

## 2. Curated segment table

Flatten once into a partitioned, clustered table and point every chart at it.

### 2.1 Table function

Add a line per host dimension you set with `setDimension` (the example uses `camera`).

```sql
CREATE SCHEMA IF NOT EXISTS `PROJECT.battery`;

CREATE OR REPLACE TABLE FUNCTION `PROJECT.battery.segments_between`(
  first_day DATE, last_day DATE
) AS (
  WITH raw AS (
    SELECT
      PARSE_DATE('%Y%m%d', event_date) AS event_date,
      TIMESTAMP_MICROS(event_timestamp) AS logged_at,
      user_pseudo_id, user_id,
      device.mobile_brand_name AS brand,
      device.mobile_model_name AS model,
      device.operating_system_version AS os_version,
      app_info.version AS app_version,
      event_params, user_properties
    FROM `PROJECT.analytics_XXXX.events_*`
    WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', first_day)
                            AND FORMAT_DATE('%Y%m%d', last_day)
      AND event_name = 'battery_segment'
      AND platform = 'ANDROID'
  ),
  flat AS (
    SELECT
      event_date, logged_at, user_pseudo_id, user_id,
      brand, model, os_version, app_version,
      -- dimensions
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'flow')       AS flow,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'app_state')  AS app_state,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'charging')   AS charging,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'screen_on')  AS screen_on,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'power_save') AS power_save,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'brightness') AS brightness,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'network')    AS network,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'camera')     AS camera, -- host dimension
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'end_reason') AS end_reason,
      -- measures (numbers can arrive as int or double; read both)
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'duration_s')  AS duration_s,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'level_start') AS level_start,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'level_end')   AS level_end,
      COALESCE((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'end_lag_s'), 0) AS end_lag_s,
      (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'drain_mah')            AS drain_mah,
      (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'avg_ma')               AS avg_ma,
      (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'current_ma_avg')       AS current_ma_avg,
      (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'temp_start_c')         AS temp_start_c,
      (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'temp_max_c')           AS temp_max_c,
      (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'thermal_headroom_max') AS thermal_headroom_max,
      (SELECT COALESCE(value.int_value, CAST(value.double_value AS INT64)) FROM UNNEST(event_params) WHERE key = 'thermal_status_max') AS thermal_status_max,
      (SELECT COALESCE(value.int_value, CAST(value.double_value AS INT64)) FROM UNNEST(event_params) WHERE key = 'est_capacity_mah')   AS est_capacity_mah,
      -- device facts (user properties, strings)
      SAFE_CAST((SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'battery_capacity_mah') AS INT64) AS battery_capacity_mah,
      SAFE_CAST((SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'battery_design_mah') AS INT64)   AS battery_design_mah,
      SAFE_CAST((SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'battery_cycle_count') AS INT64)  AS battery_cycle_count,
      (SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'battery_health')                          AS battery_health
    FROM raw
  )
  SELECT
    *,
    -- A segment ends when it is logged, except one recovered after a process
    -- death, logged at the next launch: end_lag_s is that gap.
    TIMESTAMP_SUB(logged_at, INTERVAL end_lag_s SECOND) AS ended_at,
    TIMESTAMP_SUB(logged_at, INTERVAL end_lag_s + duration_s SECOND) AS started_at,
    duration_s / 3600 AS hours,
    -- battery % used, normalised by this phone's own capacity
    SAFE_DIVIDE(drain_mah, COALESCE(battery_capacity_mah, est_capacity_mah)) * 100 AS drain_pct,
    -- passes the drain quality rules in §3
    (drain_mah IS NOT NULL
      AND COALESCE(charging, '0') = '0'
      AND end_reason != 'charging'
      AND drain_mah >= 0
      AND duration_s BETWEEN 30 AND 4 * 3600
      AND COALESCE(battery_capacity_mah, est_capacity_mah) BETWEEN 1000 AND 10000
      AND SAFE_DIVIDE(drain_mah, duration_s / 3600) < 5000) AS is_valid
  FROM flat
);
```

### 2.2 Create and backfill

```sql
CREATE TABLE IF NOT EXISTS `PROJECT.battery.segments`
PARTITION BY event_date
CLUSTER BY flow, model, app_state
AS
SELECT * FROM `PROJECT.battery.segments_between`(DATE '2026-01-01', DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY));
```

Set the first date to the day you switched reporting on.

### 2.3 Daily refresh (Scheduled Query)

```sql
DECLARE first_day DATE DEFAULT DATE_SUB(@run_date, INTERVAL 3 DAY);
DECLARE last_day  DATE DEFAULT DATE_SUB(@run_date, INTERVAL 1 DAY);

DELETE FROM `PROJECT.battery.segments` WHERE event_date BETWEEN first_day AND last_day;
INSERT INTO `PROJECT.battery.segments`
SELECT * FROM `PROJECT.battery.segments_between`(first_day, last_day);
```

Idempotent: re-running a day replaces it, so late events are picked up and nothing is counted twice.

### 2.4 Flow runs and sessions

`battery_flow` and `battery_session` share a shape, so one flat view serves both:

```sql
CREATE OR REPLACE VIEW `PROJECT.battery.runs` AS
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  TIMESTAMP_MICROS(event_timestamp) AS ended_at,
  event_name,                                   -- battery_flow | battery_session
  user_pseudo_id, device.mobile_model_name AS model, app_info.version AS app_version,
  COALESCE(
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'flow'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'app_state')) AS name,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'charging') AS charging,
  (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'duration_s') AS duration_s,
  (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'drain_mah') AS drain_mah,
  (SELECT COALESCE(value.double_value, value.int_value) FROM UNNEST(event_params) WHERE key = 'temp_max_c') AS temp_max_c,
  SAFE_CAST((SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'battery_capacity_mah') AS INT64) AS capacity_mah
FROM `PROJECT.analytics_XXXX.events_*`
WHERE event_name IN ('battery_flow', 'battery_session') AND platform = 'ANDROID';
```

Cost per flow visit — the flow-wise headline:

```sql
SELECT name AS flow,
       COUNT(*) AS visits,
       APPROX_QUANTILES(drain_mah, 100)[OFFSET(50)] AS median_mah_per_visit,
       APPROX_QUANTILES(drain_mah, 100)[OFFSET(90)] AS p90_mah_per_visit,
       SUM(drain_mah) / SUM(duration_s / 3600) AS avg_ma,
       COUNT(DISTINCT user_pseudo_id) AS devices
FROM `PROJECT.battery.runs`
WHERE event_name = 'battery_flow' AND charging = '0' AND drain_mah IS NOT NULL
  AND event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY flow HAVING visits >= 20
ORDER BY median_mah_per_visit DESC;
```

Every-user drain, foreground vs background, per release:

```sql
SELECT app_version, name AS app_state,
       SUM(SAFE_DIVIDE(drain_mah, capacity_mah) * 100) / SUM(duration_s / 3600) AS pct_per_hour,
       SUM(duration_s) / 3600 AS hours,
       COUNT(DISTINCT user_pseudo_id) AS devices
FROM `PROJECT.battery.runs`
WHERE event_name = 'battery_session' AND charging = '0' AND drain_mah >= 0
GROUP BY 1, 2 HAVING hours >= 2
ORDER BY app_version DESC, app_state;
```

## 3. Metrics — how to aggregate correctly

**Always time-weight.** Never `AVG(avg_ma)`: that gives a 10-second segment the same say as a 2-hour one.

| Metric | Formula | Use |
|---|---|---|
| **Drain rate (mA)** | `SUM(drain_mah) / SUM(hours)` | Absolute cost of a state on one kind of device |
| **Drain %/hour** | `SUM(drain_pct) / SUM(hours)` | Comparable across phones with different batteries — the headline |
| **Hours covered** | `SUM(hours)` | Confidence; hide rows under ~1 h |
| **Devices** | `COUNT(DISTINCT user_pseudo_id)` | Confidence; one odd phone should not be a finding |
| **Hot share** | `SUM(IF(thermal_headroom_max >= 0.8 OR thermal_status_max >= 2, hours, 0)) / SUM(hours)` | Share of time near or at thermal throttling |

**Quality rules** (`is_valid`): not charging and not the segment in which the plug changed (its drain mixes both), charge counter present, non-negative drain (a counter can jump after recalibration), 30 s – 4 h long, plausible capacity (1–10 Ah), rate under 5 A. Filter `WHERE is_valid` in every drain chart.

**Robust per-model numbers** — medians of each device's time-weighted rate, so one phone with a broken fuel gauge cannot move a model:

```sql
WITH per_device AS (
  SELECT model, user_pseudo_id, SUM(drain_pct) / SUM(hours) AS pct_h, SUM(hours) AS h
  FROM `PROJECT.battery.segments`
  WHERE is_valid AND app_state = 'fg'
  GROUP BY 1, 2
  HAVING h >= 0.5
)
SELECT model, COUNT(*) AS devices,
       APPROX_QUANTILES(pct_h, 100)[OFFSET(50)] AS median_pct_h,
       APPROX_QUANTILES(pct_h, 100)[OFFSET(90)] AS p90_pct_h
FROM per_device GROUP BY model HAVING devices >= 5 ORDER BY median_pct_h DESC;
```

**Useful slices.**

| Question | Filter |
|---|---|
| Idle drain, app not in use | `flow = 'none' AND app_state = 'bg' AND screen_on = '0'` |
| App in hand | `app_state = 'fg' AND screen_on = '1'` |
| Screen cost | the above, split by `brightness` — hold it constant before comparing flows |
| Network cost | same slice, split by `network` |
| Cost of a feature | same flow, split by your dimension (e.g. `camera = 'preview'` vs `'off'`), same models |
| Heat problems | `thermal_headroom_max >= 0.8`, or `thermal_status_max >= 2`, or `temp_max_c >= 42` |

## 4. Dashboard ideas

Build in **Looker Studio** or **Metabase** on `PROJECT.battery.segments` and `PROJECT.battery.runs`. Global controls: date range, `app_version`, `brand`, `model`.

**Fleet overview** — devices reporting, hours measured, foreground %/h, idle %/h, and a drain trend line per `app_version` (a regressing release shows as a step):

```sql
SELECT event_date, app_version,
       SUM(drain_pct) / SUM(hours) AS pct_per_hour,
       COUNT(DISTINCT user_pseudo_id) AS devices
FROM `PROJECT.battery.segments`
WHERE is_valid AND app_state = 'fg'
GROUP BY 1, 2
HAVING SUM(hours) >= 2;
```

**Flows** — drain rate by flow, and total cost (rate × time: a cheap flow used all day can outweigh an expensive rare one):

```sql
SELECT flow,
       SUM(drain_pct) / SUM(hours) AS pct_per_hour,
       SUM(drain_mah) / SUM(hours) AS avg_ma,
       SUM(drain_pct) AS total_pct_used,
       SUM(hours) AS hours,
       COUNT(DISTINCT user_pseudo_id) AS devices
FROM `PROJECT.battery.segments`
WHERE is_valid AND app_state = 'fg'
GROUP BY flow HAVING hours >= 1
ORDER BY pct_per_hour DESC;
```

**Cost of a feature** — the difference against the same flow with it off, on the same models:

```sql
SELECT model,
       SUM(IF(camera = 'preview', drain_mah, 0)) / NULLIF(SUM(IF(camera = 'preview', hours, 0)), 0) AS camera_ma,
       SUM(IF(camera = 'off',     drain_mah, 0)) / NULLIF(SUM(IF(camera = 'off',     hours, 0)), 0) AS no_camera_ma,
       SUM(IF(camera = 'preview', hours, 0)) AS camera_hours
FROM `PROJECT.battery.segments`
WHERE is_valid AND app_state = 'fg'
GROUP BY model HAVING camera_hours >= 0.5
ORDER BY camera_ma - no_camera_ma DESC;
```

**Heat** — hot share and battery temperature by flow:

```sql
SELECT flow,
       SUM(IF(thermal_headroom_max >= 0.8 OR thermal_status_max >= 2, hours, 0)) / SUM(hours) AS hot_share,
       APPROX_QUANTILES(temp_max_c, 100)[OFFSET(50)] AS p50_temp_c,
       APPROX_QUANTILES(temp_max_c, 100)[OFFSET(90)] AS p90_temp_c,
       SUM(hours) AS hours
FROM `PROJECT.battery.segments`
WHERE is_valid AND thermal_status_max IS NOT NULL
GROUP BY flow HAVING hours >= 1 ORDER BY hot_share DESC;
```

Thermal *status* is coarse: many OEMs define only the SEVERE threshold, so it reads `none` until the phone is already hot. *Headroom* (Android 11+) is continuous against that threshold — 1.0 = at it, each 0.1 ≈ 3 °C — so lead with it. Devices without a thermal HAL report status `0` forever and never a headroom; their zeros are not readings. Restrict status charts to devices that have ever reported a headroom:

```sql
WITH thermal_capable AS (
  SELECT DISTINCT user_pseudo_id FROM `PROJECT.battery.segments`
  WHERE thermal_headroom_max IS NOT NULL
)
SELECT ... FROM `PROJECT.battery.segments`
WHERE user_pseudo_id IN (SELECT user_pseudo_id FROM thermal_capable) ...
```

**Battery health** — latest facts per device, compared with the design capacity and with the model's median:

```sql
WITH latest AS (
  SELECT user_pseudo_id, brand, model,
         ARRAY_AGG(STRUCT(battery_capacity_mah, battery_design_mah, battery_cycle_count, battery_health)
                   ORDER BY ended_at DESC LIMIT 1)[OFFSET(0)] AS f
  FROM `PROJECT.battery.segments`
  WHERE event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
  GROUP BY 1, 2, 3
),
per_model AS (
  SELECT model, APPROX_QUANTILES(f.battery_capacity_mah, 100)[OFFSET(50)] AS model_median_mah
  FROM latest WHERE f.battery_capacity_mah IS NOT NULL GROUP BY model
)
SELECT l.user_pseudo_id, l.brand, l.model,
       f.battery_capacity_mah, p.model_median_mah,
       SAFE_DIVIDE(f.battery_capacity_mah, p.model_median_mah) AS capacity_vs_model,
       f.battery_design_mah,
       SAFE_DIVIDE(f.battery_capacity_mah, f.battery_design_mah) AS health_vs_design,
       f.battery_cycle_count, f.battery_health
FROM latest l LEFT JOIN per_model p USING (model)
ORDER BY capacity_vs_model;
```

Under ~0.8 of design is a worn battery. A few percent over 1.0 is normal on OEMs that rescale the displayed percentage.

**Charging** — charging segments (`charging = '1'`, excluding `end_reason = 'charging'`) have negative `drain_mah`: net charge gained. Does the charger keep up while a feature runs?

```sql
SELECT flow,
       -SUM(drain_mah) / SUM(hours) AS net_charge_ma,
       APPROX_QUANTILES(temp_max_c, 100)[OFFSET(90)] AS p90_temp_c,
       SUM(hours) AS hours
FROM `PROJECT.battery.segments`
WHERE charging = '1' AND end_reason != 'charging' AND drain_mah IS NOT NULL
GROUP BY 1 HAVING hours >= 0.5
ORDER BY net_charge_ma;
```

**Data quality** — show coverage so nobody reads a chart blind:

```sql
SELECT event_date,
       COUNT(*) AS segments,
       COUNTIF(is_valid) / COUNT(*) AS valid_share,
       COUNTIF(drain_mah IS NULL) / COUNT(*) AS no_charge_counter_share,
       COUNTIF(end_reason = 'process_death') / COUNT(*) AS process_death_share,
       COUNT(DISTINCT user_pseudo_id) AS devices
FROM `PROJECT.battery.segments`
GROUP BY event_date ORDER BY event_date;
```

Models near 100 % `no_charge_counter_share` only report battery % and should be left out of mA charts.

## 5. Reading the numbers

- **Small differences need hours behind them.** Hide any bar with under ~1 hour or 5 devices.
- **Compare like with like.** A feature's cost is only meaningful against the same flow on the same model.
- **%/h is the headline, mA is the diagnosis.** Users feel %/h; engineers fix mA.
- **A release regression** shows as one `app_version` line sitting above the others on the same days — then look at the flows page for what moved.
