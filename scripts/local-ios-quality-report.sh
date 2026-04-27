#!/usr/bin/env bash

set -euo pipefail

DEFAULT_STORE_PATH=".context/device-live-latest/Library/Application Support/default.store"
LEGACY_DEFAULT_STORE_PATH=".context/device-live-latest/default.store"

UPDATE_SNAPSHOT=1
RESET_SNAPSHOT=0
SNAPSHOT_PATH=""
STORE_PATH=""

print_usage() {
  cat <<'USAGE'
Usage: local-ios-quality-report.sh [options] [path/to/default.store]

Options:
  --snapshot-file <path>   Where to read/write the prior-run snapshot.
                           Default: <store>.report-snapshot
  --no-snapshot-update     Compute deltas, but do not overwrite the snapshot.
  --reset-snapshot         Discard the existing snapshot before running.
  -h, --help               Show this help text.

Each run prints the cumulative store report, plus a "Since last report" delta
against the saved snapshot if one exists. The snapshot is then refreshed
unless --no-snapshot-update is passed.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot-file)
      [[ $# -ge 2 ]] || { echo "--snapshot-file requires a value" >&2; exit 2; }
      SNAPSHOT_PATH="$2"
      shift 2
      ;;
    --no-snapshot-update)
      UPDATE_SNAPSHOT=0
      shift
      ;;
    --reset-snapshot)
      RESET_SNAPSHOT=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      [[ $# -gt 0 ]] && STORE_PATH="$1"
      shift || true
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$STORE_PATH" ]]; then
        STORE_PATH="$1"
        shift
      else
        echo "Unexpected positional argument: $1" >&2
        print_usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$STORE_PATH" ]]; then
  if [[ -f "$DEFAULT_STORE_PATH" ]]; then
    STORE_PATH="$DEFAULT_STORE_PATH"
  else
    STORE_PATH="$LEGACY_DEFAULT_STORE_PATH"
  fi
fi

if [[ ! -f "$STORE_PATH" ]]; then
  echo "SwiftData store not found: $STORE_PATH" >&2
  echo "Usage: $0 [path/to/default.store]" >&2
  exit 1
fi

if [[ -z "$SNAPSHOT_PATH" ]]; then
  SNAPSHOT_PATH="${STORE_PATH}.report-snapshot"
fi

if [[ "$RESET_SNAPSHOT" -eq 1 && -f "$SNAPSHOT_PATH" ]]; then
  rm "$SNAPSHOT_PATH"
fi

CURRENT_METRICS_FILE="$(mktemp)"
trap 'rm -f "$CURRENT_METRICS_FILE"' EXIT

# Pull a single normalized snapshot so the delta and the printed report agree.
sqlite3 "$STORE_PATH" <<'SQL' > "$CURRENT_METRICS_FILE"
.headers off
.mode list
.separator "|"

WITH readings AS (
  SELECT
    ZROUGHNESSRMS AS rms,
    ZISPOTHOLE AS is_pothole,
    ZRECORDEDAT AS recorded_at,
    ZDROPPEDBYPRIVACYZONE AS dropped_by_privacy_zone,
    ZENDPOINTTRIMMEDAT AS endpoint_trimmed_at,
    ZUPLOADREADYAT AS upload_ready_at,
    ZUPLOADEDAT AS uploaded_at,
    ZDRIVESESSIONID AS drive_session_id
  FROM ZREADINGRECORD
)
SELECT 'now_unix', CAST(strftime('%s','now') AS TEXT)
UNION ALL SELECT 'total_samples', CAST(COUNT(*) AS TEXT) FROM readings
UNION ALL SELECT 'accepted_samples', CAST(COUNT(*) FILTER (WHERE dropped_by_privacy_zone = 0) AS TEXT) FROM readings
UNION ALL SELECT 'privacy_filtered_samples', CAST(COUNT(*) FILTER (WHERE dropped_by_privacy_zone = 1) AS TEXT) FROM readings
UNION ALL SELECT 'upload_ready_samples', CAST(COUNT(*) FILTER (WHERE upload_ready_at IS NOT NULL) AS TEXT) FROM readings
UNION ALL SELECT 'pending_upload_samples', CAST(COUNT(*) FILTER (
    WHERE uploaded_at IS NULL
      AND dropped_by_privacy_zone = 0
      AND endpoint_trimmed_at IS NULL
      AND (drive_session_id IS NULL OR upload_ready_at IS NOT NULL)
  ) AS TEXT) FROM readings
UNION ALL SELECT 'uploaded_samples', CAST(COUNT(*) FILTER (WHERE uploaded_at IS NOT NULL) AS TEXT) FROM readings
UNION ALL SELECT 'endpoint_trimmed_samples', CAST(COUNT(*) FILTER (WHERE endpoint_trimmed_at IS NOT NULL) AS TEXT) FROM readings
UNION ALL SELECT 'sensor_pothole_candidates', CAST(COUNT(*) FILTER (WHERE is_pothole = 1) AS TEXT) FROM readings
UNION ALL SELECT 'last_sample_unix', COALESCE(CAST(CAST(MAX(recorded_at) + 978307200 AS INTEGER) AS TEXT), '') FROM readings
UNION ALL SELECT 'raw_drive_sessions', CAST(COUNT(*) AS TEXT) FROM ZDRIVESESSIONRECORD
UNION ALL SELECT 'sealed_sessions', CAST(COALESCE(SUM(ZISSEALED), 0) AS TEXT) FROM ZDRIVESESSIONRECORD
UNION ALL SELECT 'grouped_trips', CAST(COALESCE((
    SELECT SUM(starts_new_trip) FROM (
      SELECT
        CASE
          WHEN LAG(COALESCE(ZENDEDAT, ZSTARTEDAT)) OVER (ORDER BY ZSTARTEDAT) IS NULL THEN 1
          WHEN ZSTARTEDAT - LAG(COALESCE(ZENDEDAT, ZSTARTEDAT)) OVER (ORDER BY ZSTARTEDAT) > 60 THEN 1
          ELSE 0
        END AS starts_new_trip
      FROM ZDRIVESESSIONRECORD
    )
  ), 0) AS TEXT)
UNION ALL SELECT 'manual_pothole_marks', CAST(COUNT(*) AS TEXT) FROM ZPOTHOLEACTIONRECORD
UNION ALL SELECT 'manual_marks_pending_upload',
    CAST(COUNT(*) FILTER (WHERE ZUPLOADSTATERAWVALUE = 'pending_upload') AS TEXT) FROM ZPOTHOLEACTIONRECORD
UNION ALL SELECT 'photo_reports', CAST(COUNT(*) AS TEXT) FROM ZPOTHOLEREPORTRECORD
UNION ALL SELECT 'photo_reports_pending',
    CAST(COUNT(*) FILTER (WHERE ZUPLOADSTATERAWVALUE NOT IN ('uploaded', 'failed_permanent')) AS TEXT)
    FROM ZPOTHOLEREPORTRECORD
UNION ALL SELECT 'upload_batches_succeeded',
    CAST(COUNT(*) FILTER (WHERE ZSTATUSRAWVALUE = 'succeeded') AS TEXT) FROM ZUPLOADBATCH
UNION ALL SELECT 'upload_batches_pending',
    CAST(COUNT(*) FILTER (WHERE ZSTATUSRAWVALUE = 'pending') AS TEXT) FROM ZUPLOADBATCH
UNION ALL SELECT 'upload_batches_failed_permanent',
    CAST(COUNT(*) FILTER (WHERE ZSTATUSRAWVALUE = 'failed_permanent') AS TEXT) FROM ZUPLOADBATCH;
SQL

# Helper to read a metric out of the current snapshot file.
metric_value() {
  local key="$1"
  local file="$2"
  local value
  value="$(awk -F'|' -v k="$key" '$1 == k { print $2; exit }' "$file" 2>/dev/null || true)"
  echo "${value:-}"
}

format_relative_time() {
  local target_unix="$1"
  if [[ -z "$target_unix" ]]; then
    echo "—"
    return
  fi
  local now
  now="$(date +%s)"
  local diff=$(( now - target_unix ))
  if (( diff < 0 )); then diff=0; fi
  if (( diff < 60 )); then
    echo "${diff}s ago"
  elif (( diff < 3600 )); then
    echo "$(( diff / 60 ))m ago"
  elif (( diff < 86400 )); then
    printf '%dh %02dm ago\n' "$(( diff / 3600 ))" "$(( (diff % 3600) / 60 ))"
  else
    printf '%dd %02dh ago\n' "$(( diff / 86400 ))" "$(( (diff % 86400) / 3600 ))"
  fi
}

format_absolute_time() {
  local target_unix="$1"
  if [[ -z "$target_unix" ]]; then
    echo "—"
    return
  fi
  date -r "$target_unix" '+%Y-%m-%d %H:%M:%S %Z'
}

print_delta_row() {
  local label="$1"
  local before="$2"
  local after="$3"
  before="${before:-0}"
  after="${after:-0}"
  local diff=$(( after - before ))
  local sign=""
  if (( diff > 0 )); then sign="+"; fi
  printf '  %-32s %s%-6s (was %s, now %s)\n' "$label" "$sign" "$diff" "$before" "$after"
}

DELTA_LABELS=(
  'total_samples:Road samples (total)'
  'accepted_samples:Accepted samples'
  'privacy_filtered_samples:Privacy-filtered samples'
  'pending_upload_samples:Pending upload samples'
  'uploaded_samples:Uploaded samples'
  'endpoint_trimmed_samples:Endpoint-trimmed samples'
  'sensor_pothole_candidates:Sensor pothole candidates'
  'raw_drive_sessions:Drive sessions (raw)'
  'sealed_sessions:Sealed drive sessions'
  'grouped_trips:Grouped trips'
  'manual_pothole_marks:Manual pothole marks'
  'manual_marks_pending_upload:Manual marks pending upload'
  'photo_reports:Photo reports'
  'photo_reports_pending:Photo reports pending'
  'upload_batches_succeeded:Upload batches succeeded'
  'upload_batches_pending:Upload batches pending'
  'upload_batches_failed_permanent:Upload batches failed (permanent)'
)

echo "== Since last report =="
if [[ -f "$SNAPSHOT_PATH" ]]; then
  prev_unix="$(metric_value now_unix "$SNAPSHOT_PATH")"
  prev_last_sample_unix="$(metric_value last_sample_unix "$SNAPSHOT_PATH")"
  current_last_sample_unix="$(metric_value last_sample_unix "$CURRENT_METRICS_FILE")"

  if [[ -n "$prev_unix" ]]; then
    echo "  Snapshot age:                    $(format_relative_time "$prev_unix") (taken $(format_absolute_time "$prev_unix"))"
  fi
  if [[ -n "$current_last_sample_unix" ]]; then
    echo "  Latest sample on device:         $(format_relative_time "$current_last_sample_unix") ($(format_absolute_time "$current_last_sample_unix"))"
  fi
  if [[ -n "$prev_last_sample_unix" && -n "$current_last_sample_unix" ]]; then
    if (( current_last_sample_unix > prev_last_sample_unix )); then
      gap_minutes=$(( (current_last_sample_unix - prev_last_sample_unix + 30) / 60 ))
      echo "  New sampling window:             ~${gap_minutes} min of new samples"
    elif (( current_last_sample_unix == prev_last_sample_unix )); then
      echo "  New sampling window:             no new samples since last snapshot"
    fi
  fi
  echo ""

  any_changes=0
  for entry in "${DELTA_LABELS[@]}"; do
    metric="${entry%%:*}"
    label="${entry#*:}"
    before="$(metric_value "$metric" "$SNAPSHOT_PATH")"
    after="$(metric_value "$metric" "$CURRENT_METRICS_FILE")"
    before="${before:-0}"
    after="${after:-0}"
    if [[ "$before" != "$after" ]]; then
      print_delta_row "$label" "$before" "$after"
      any_changes=1
    fi
  done

  if [[ "$any_changes" -eq 0 ]]; then
    echo "  No counter changes since the last snapshot."
  fi
else
  echo "  No prior snapshot at: $SNAPSHOT_PATH"
  echo "  This run becomes the baseline. Re-run after the next drive to see deltas."
fi

echo ""

# Full cumulative report (kept for parity with prior behavior).
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

if [[ "$UPDATE_SNAPSHOT" -eq 1 ]]; then
  cp "$CURRENT_METRICS_FILE" "$SNAPSHOT_PATH"
fi
