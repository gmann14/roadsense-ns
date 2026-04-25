#!/usr/bin/env bash

set -euo pipefail

STORE_PATH="${1:-.context/device-live-latest/default.store}"

if [[ ! -f "$STORE_PATH" ]]; then
  echo "SwiftData store not found: $STORE_PATH" >&2
  echo "Usage: $0 [path/to/default.store]" >&2
  exit 1
fi

sqlite3 -header -column "$STORE_PATH" <<'SQL'
WITH
readings AS (
  SELECT
    ZROUGHNESSRMS AS rms,
    ZSPEEDKMH AS speed_kmh,
    ZDROPPEDBYPRIVACYZONE AS dropped_by_privacy_zone,
    ZUPLOADREADYAT AS upload_ready_at,
    ZUPLOADEDAT AS uploaded_at,
    ZDRIVESESSIONID AS drive_session_id
  FROM ZREADINGRECORD
),
accepted AS (
  SELECT * FROM readings WHERE dropped_by_privacy_zone = 0
),
ordered AS (
  SELECT
    rms,
    percent_rank() OVER (ORDER BY rms) AS percentile_rank
  FROM accepted
),
sessions AS (
  SELECT
    Z_PK AS row_id,
    ZSTARTEDAT AS started_at,
    COALESCE(ZENDEDAT, ZSTARTEDAT) AS ended_at,
    ZISSEALED AS is_sealed
  FROM ZDRIVESESSIONRECORD
),
session_groups AS (
  SELECT
    *,
    CASE
      WHEN LAG(ended_at) OVER (ORDER BY started_at) IS NULL THEN 1
      WHEN started_at - LAG(ended_at) OVER (ORDER BY started_at) > 60 THEN 1
      ELSE 0
    END AS starts_new_trip
  FROM sessions
),
trip_count AS (
  SELECT COALESCE(SUM(starts_new_trip), 0) AS trips FROM session_groups
)
SELECT
  COUNT(*) AS accepted_readings,
  ROUND(MIN(rms), 3) AS min_rms,
  ROUND(AVG(rms), 3) AS avg_rms,
  ROUND(MAX(rms), 3) AS max_rms,
  ROUND(AVG(speed_kmh), 1) AS avg_speed_kmh
FROM accepted;

WITH
accepted AS (
  SELECT ZROUGHNESSRMS AS rms
  FROM ZREADINGRECORD
  WHERE ZDROPPEDBYPRIVACYZONE = 0
),
ordered AS (
  SELECT
    rms,
    percent_rank() OVER (ORDER BY rms) AS percentile_rank
  FROM accepted
)
SELECT 'p50' AS metric, ROUND(MIN(rms), 3) AS rms FROM ordered WHERE percentile_rank >= 0.50
UNION ALL
SELECT 'p75', ROUND(MIN(rms), 3) FROM ordered WHERE percentile_rank >= 0.75
UNION ALL
SELECT 'p90', ROUND(MIN(rms), 3) FROM ordered WHERE percentile_rank >= 0.90
UNION ALL
SELECT 'p95', ROUND(MIN(rms), 3) FROM ordered WHERE percentile_rank >= 0.95;

WITH accepted AS (
  SELECT ZROUGHNESSRMS AS rms
  FROM ZREADINGRECORD
  WHERE ZDROPPEDBYPRIVACYZONE = 0
)
SELECT
  CASE
    WHEN rms < 0.05 THEN 'smooth'
    WHEN rms < 0.09 THEN 'fair'
    WHEN rms < 0.14 THEN 'rough'
    ELSE 'very_rough'
  END AS roughness_bucket,
  COUNT(*) AS readings,
  ROUND(100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM accepted), 0), 1) AS pct
FROM accepted
GROUP BY roughness_bucket
ORDER BY MIN(rms);

WITH
sessions AS (
  SELECT
    ZSTARTEDAT AS started_at,
    COALESCE(ZENDEDAT, ZSTARTEDAT) AS ended_at,
    ZISSEALED AS is_sealed
  FROM ZDRIVESESSIONRECORD
),
session_groups AS (
  SELECT
    *,
    CASE
      WHEN LAG(ended_at) OVER (ORDER BY started_at) IS NULL THEN 1
      WHEN started_at - LAG(ended_at) OVER (ORDER BY started_at) > 60 THEN 1
      ELSE 0
    END AS starts_new_trip
  FROM sessions
)
SELECT
  COUNT(*) AS raw_drive_sessions,
  COALESCE(SUM(starts_new_trip), 0) AS grouped_trips,
  COALESCE(SUM(is_sealed), 0) AS sealed_sessions,
  ROUND(SUM((ended_at - started_at) / 60.0), 1) AS recorded_minutes
FROM session_groups;

WITH pending AS (
  SELECT *
  FROM ZREADINGRECORD
  WHERE ZUPLOADEDAT IS NULL
    AND ZDROPPEDBYPRIVACYZONE = 0
    AND ZENDPOINTTRIMMEDAT IS NULL
    AND (ZDRIVESESSIONID IS NULL OR ZUPLOADREADYAT IS NOT NULL)
)
SELECT
  COUNT(*) AS pending_readings,
  COUNT(DISTINCT ZDRIVESESSIONID) AS pending_drive_session_fragments,
  COUNT(*) FILTER (WHERE ZDRIVESESSIONID IS NULL) AS pending_legacy_readings
FROM pending;
SQL
