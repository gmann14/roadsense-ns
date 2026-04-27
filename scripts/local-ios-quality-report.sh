#!/usr/bin/env bash

set -euo pipefail

DEFAULT_STORE_PATH=".context/device-live-latest/Library/Application Support/default.store"
LEGACY_DEFAULT_STORE_PATH=".context/device-live-latest/default.store"

if [[ $# -gt 0 ]]; then
  STORE_PATH="$1"
elif [[ -f "$DEFAULT_STORE_PATH" ]]; then
  STORE_PATH="$DEFAULT_STORE_PATH"
else
  STORE_PATH="$LEGACY_DEFAULT_STORE_PATH"
fi

if [[ ! -f "$STORE_PATH" ]]; then
  echo "SwiftData store not found: $STORE_PATH" >&2
  echo "Usage: $0 [path/to/default.store]" >&2
  exit 1
fi

sqlite3 -header -column "$STORE_PATH" <<'SQL'
.headers on
.mode column
.nullvalue none

.print '== Road samples =='
WITH readings AS (
  SELECT
    ZROUGHNESSRMS AS rms,
    ZSPEEDKMH AS speed_kmh,
    ZISPOTHOLE AS is_pothole,
    ZRECORDEDAT AS recorded_at,
    ZDROPPEDBYPRIVACYZONE AS dropped_by_privacy_zone,
    ZENDPOINTTRIMMEDAT AS endpoint_trimmed_at,
    ZUPLOADREADYAT AS upload_ready_at,
    ZUPLOADEDAT AS uploaded_at,
    ZDRIVESESSIONID AS drive_session_id
  FROM ZREADINGRECORD
),
summary AS (
  SELECT
    COUNT(*) AS total_samples,
    COUNT(*) FILTER (WHERE dropped_by_privacy_zone = 0) AS accepted_samples,
    COUNT(*) FILTER (WHERE upload_ready_at IS NOT NULL) AS upload_ready_samples,
    COUNT(*) FILTER (
      WHERE uploaded_at IS NULL
        AND dropped_by_privacy_zone = 0
        AND endpoint_trimmed_at IS NULL
        AND (drive_session_id IS NULL OR upload_ready_at IS NOT NULL)
    ) AS pending_upload_samples,
    COUNT(*) FILTER (WHERE uploaded_at IS NOT NULL) AS uploaded_samples,
    COUNT(*) FILTER (WHERE endpoint_trimmed_at IS NOT NULL) AS endpoint_trimmed_samples,
    COUNT(*) FILTER (WHERE dropped_by_privacy_zone = 1) AS privacy_filtered_samples,
    COUNT(*) FILTER (WHERE is_pothole = 1) AS sensor_pothole_candidates,
    datetime(MAX(recorded_at) + 978307200, 'unixepoch', 'localtime') AS last_sample_at
  FROM readings
)
SELECT 'total_samples' AS metric, CAST(total_samples AS TEXT) AS value FROM summary
UNION ALL SELECT 'accepted_samples', CAST(accepted_samples AS TEXT) FROM summary
UNION ALL SELECT 'upload_ready_samples', CAST(upload_ready_samples AS TEXT) FROM summary
UNION ALL SELECT 'pending_upload_samples', CAST(pending_upload_samples AS TEXT) FROM summary
UNION ALL SELECT 'uploaded_samples', CAST(uploaded_samples AS TEXT) FROM summary
UNION ALL SELECT 'endpoint_trimmed_samples', CAST(endpoint_trimmed_samples AS TEXT) FROM summary
UNION ALL SELECT 'privacy_filtered_samples', CAST(privacy_filtered_samples AS TEXT) FROM summary
UNION ALL SELECT 'sensor_pothole_candidates', CAST(sensor_pothole_candidates AS TEXT) FROM summary
UNION ALL SELECT 'last_sample_at', COALESCE(last_sample_at, 'none') FROM summary;

.print ''
.print '== Roughness summary =='
WITH accepted AS (
  SELECT ZROUGHNESSRMS AS rms, ZSPEEDKMH AS speed_kmh
  FROM ZREADINGRECORD
  WHERE ZDROPPEDBYPRIVACYZONE = 0
)
SELECT 'min_rms' AS metric, COALESCE(CAST(ROUND(MIN(rms), 3) AS TEXT), 'none') AS value FROM accepted
UNION ALL SELECT 'avg_rms', COALESCE(CAST(ROUND(AVG(rms), 3) AS TEXT), 'none') FROM accepted
UNION ALL SELECT 'max_rms', COALESCE(CAST(ROUND(MAX(rms), 3) AS TEXT), 'none') FROM accepted
UNION ALL SELECT 'avg_speed_kmh', COALESCE(CAST(ROUND(AVG(speed_kmh), 1) AS TEXT), 'none') FROM accepted;

.print ''
.print '== Roughness percentiles =='
WITH accepted AS (
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
SELECT 'p50' AS metric, COALESCE(CAST(ROUND(MIN(rms), 3) AS TEXT), 'none') AS value FROM ordered WHERE percentile_rank >= 0.50
UNION ALL
SELECT 'p75', COALESCE(CAST(ROUND(MIN(rms), 3) AS TEXT), 'none') FROM ordered WHERE percentile_rank >= 0.75
UNION ALL
SELECT 'p90', COALESCE(CAST(ROUND(MIN(rms), 3) AS TEXT), 'none') FROM ordered WHERE percentile_rank >= 0.90
UNION ALL
SELECT 'p95', COALESCE(CAST(ROUND(MIN(rms), 3) AS TEXT), 'none') FROM ordered WHERE percentile_rank >= 0.95;

.print ''
.print '== Roughness buckets =='
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
  COUNT(*) AS samples,
  ROUND(100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM accepted), 0), 1) AS pct
FROM accepted
GROUP BY roughness_bucket
ORDER BY MIN(rms);

.print ''
.print '== Trips and sessions =='
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
),
summary AS (
  SELECT
    COUNT(*) AS raw_drive_sessions,
    COALESCE(SUM(starts_new_trip), 0) AS grouped_trips,
    COALESCE(SUM(is_sealed), 0) AS sealed_sessions,
    ROUND(COALESCE(SUM((ended_at - started_at) / 60.0), 0), 1) AS recorded_minutes,
    datetime(MIN(started_at) + 978307200, 'unixepoch', 'localtime') AS first_session_started,
    datetime(MAX(ended_at) + 978307200, 'unixepoch', 'localtime') AS last_session_seen
  FROM session_groups
)
SELECT 'raw_drive_sessions' AS metric, CAST(raw_drive_sessions AS TEXT) AS value FROM summary
UNION ALL SELECT 'grouped_trips', CAST(grouped_trips AS TEXT) FROM summary
UNION ALL SELECT 'sealed_sessions', CAST(sealed_sessions AS TEXT) FROM summary
UNION ALL SELECT 'recorded_minutes', CAST(recorded_minutes AS TEXT) FROM summary
UNION ALL SELECT 'first_session_started', COALESCE(first_session_started, 'none') FROM summary
UNION ALL SELECT 'last_session_seen', COALESCE(last_session_seen, 'none') FROM summary;

.print ''
.print '== Upload batches =='
SELECT
  ZSTATUSRAWVALUE AS status,
  COUNT(*) AS batches,
  COALESCE(SUM(ZREADINGCOUNT), 0) AS samples,
  COALESCE(SUM(ZACCEPTEDCOUNT), 0) AS accepted,
  COALESCE(SUM(ZREJECTEDCOUNT), 0) AS rejected,
  datetime(MAX(ZLASTATTEMPTAT) + 978307200, 'unixepoch', 'localtime') AS last_attempt_at
FROM ZUPLOADBATCH
GROUP BY ZSTATUSRAWVALUE
ORDER BY ZSTATUSRAWVALUE;

.print ''
.print '== Pothole marks =='
SELECT
  ZACTIONTYPERAWVALUE AS action_type,
  ZUPLOADSTATERAWVALUE AS upload_state,
  COUNT(*) AS marks,
  datetime(MAX(ZRECORDEDAT) + 978307200, 'unixepoch', 'localtime') AS last_marked_at
FROM ZPOTHOLEACTIONRECORD
GROUP BY ZACTIONTYPERAWVALUE, ZUPLOADSTATERAWVALUE
ORDER BY action_type, upload_state;

.print ''
.print '== Photo reports =='
SELECT
  ZUPLOADSTATERAWVALUE AS upload_state,
  COUNT(*) AS photos,
  COALESCE(SUM(ZBYTESIZE), 0) AS bytes,
  datetime(MAX(ZCAPTUREDAT) + 978307200, 'unixepoch', 'localtime') AS last_captured_at
FROM ZPOTHOLEREPORTRECORD
GROUP BY ZUPLOADSTATERAWVALUE
ORDER BY upload_state;
SQL
