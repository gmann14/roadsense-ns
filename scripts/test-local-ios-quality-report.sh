#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STORE_PATH="$TMP_DIR/default.store"
SNAPSHOT_PATH="$TMP_DIR/default.store.report-snapshot"
FIRST_OUTPUT="$TMP_DIR/report-1.txt"
SECOND_OUTPUT="$TMP_DIR/report-2.txt"
THIRD_OUTPUT="$TMP_DIR/report-3.txt"

sqlite3 "$STORE_PATH" <<'SQL'
CREATE TABLE ZREADINGRECORD (
  ZROUGHNESSRMS REAL,
  ZSPEEDKMH REAL,
  ZISPOTHOLE INTEGER,
  ZRECORDEDAT REAL,
  ZDROPPEDBYPRIVACYZONE INTEGER,
  ZENDPOINTTRIMMEDAT REAL,
  ZUPLOADREADYAT REAL,
  ZUPLOADEDAT REAL,
  ZDRIVESESSIONID TEXT
);

INSERT INTO ZREADINGRECORD VALUES
  (0.04, 42.0, 0, 100.0, 0, NULL, 110.0, 120.0, 'trip-a'),
  (0.11, 48.0, 1, 130.0, 0, NULL, 135.0, NULL, 'trip-a'),
  (0.21, 30.0, 0, 140.0, 1, NULL, NULL, NULL, 'trip-a'),
  (0.08, 36.0, 0, 150.0, 0, 160.0, NULL, NULL, 'trip-a');

CREATE TABLE ZDRIVESESSIONRECORD (
  ZSTARTEDAT REAL,
  ZENDEDAT REAL,
  ZISSEALED INTEGER
);

INSERT INTO ZDRIVESESSIONRECORD VALUES
  (10.0, 70.0, 1),
  (100.0, 160.0, 1),
  (500.0, 620.0, 0);

CREATE TABLE ZUPLOADBATCH (
  ZSTATUSRAWVALUE TEXT,
  ZREADINGCOUNT INTEGER,
  ZACCEPTEDCOUNT INTEGER,
  ZREJECTEDCOUNT INTEGER,
  ZLASTATTEMPTAT REAL
);

INSERT INTO ZUPLOADBATCH VALUES
  ('pending', 1, 0, 0, NULL),
  ('succeeded', 1, 1, 0, 170.0);

CREATE TABLE ZPOTHOLEACTIONRECORD (
  ZACTIONTYPERAWVALUE TEXT,
  ZUPLOADSTATERAWVALUE TEXT,
  ZUPLOADEDAT REAL,
  ZRECORDEDAT REAL
);

INSERT INTO ZPOTHOLEACTIONRECORD VALUES
  ('manual_report', 'pending_upload', NULL, 180.0),
  ('confirm_present', 'pending_upload', 190.0, 190.0);

CREATE TABLE ZPOTHOLEREPORTRECORD (
  ZUPLOADSTATERAWVALUE TEXT,
  ZBYTESIZE INTEGER,
  ZCAPTUREDAT REAL
);

INSERT INTO ZPOTHOLEREPORTRECORD VALUES
  ('pending_metadata', 2048, 200.0);
SQL

require_output() {
  local output_path="$1"
  local pattern="$2"
  if ! grep -Eq "$pattern" "$output_path"; then
    echo "Missing expected report pattern: $pattern" >&2
    echo "--- report ---" >&2
    cat "$output_path" >&2
    exit 1
  fi
}

reject_output() {
  local output_path="$1"
  local pattern="$2"
  if grep -Eq "$pattern" "$output_path"; then
    echo "Unexpected report pattern present: $pattern" >&2
    echo "--- report ---" >&2
    cat "$output_path" >&2
    exit 1
  fi
}

# --- First run: fresh snapshot, baseline message ---
"$ROOT_DIR/scripts/local-ios-quality-report.sh" "$STORE_PATH" > "$FIRST_OUTPUT"

require_output "$FIRST_OUTPUT" 'Since last report'
require_output "$FIRST_OUTPUT" 'No prior snapshot at'
require_output "$FIRST_OUTPUT" 'baseline'
require_output "$FIRST_OUTPUT" 'total_samples[[:space:]]+4'
require_output "$FIRST_OUTPUT" 'accepted_samples[[:space:]]+3'
require_output "$FIRST_OUTPUT" 'pending_upload_samples[[:space:]]+1'
require_output "$FIRST_OUTPUT" 'endpoint_trimmed_samples[[:space:]]+1'
require_output "$FIRST_OUTPUT" 'privacy_filtered_samples[[:space:]]+1'
require_output "$FIRST_OUTPUT" 'sensor_pothole_candidates[[:space:]]+1'
require_output "$FIRST_OUTPUT" 'grouped_trips[[:space:]]+2'
require_output "$FIRST_OUTPUT" 'manual_report[[:space:]]+pending_upload[[:space:]]+1'
require_output "$FIRST_OUTPUT" 'pending_metadata[[:space:]]+1[[:space:]]+2048'

if [[ ! -f "$SNAPSHOT_PATH" ]]; then
  echo "Expected snapshot file at $SNAPSHOT_PATH after first run" >&2
  exit 1
fi

# --- Second run: no changes since the snapshot ---
"$ROOT_DIR/scripts/local-ios-quality-report.sh" "$STORE_PATH" > "$SECOND_OUTPUT"

require_output "$SECOND_OUTPUT" 'Since last report'
require_output "$SECOND_OUTPUT" 'No counter changes since the last snapshot'
reject_output "$SECOND_OUTPUT" 'baseline'

# --- Insert "new drive" data, then run again ---
sqlite3 "$STORE_PATH" <<'SQL'
INSERT INTO ZREADINGRECORD VALUES
  (0.06, 51.0, 0, 1000.0, 0, NULL, 1010.0, NULL, 'trip-b'),
  (0.18, 54.0, 1, 1010.0, 0, NULL, 1010.0, NULL, 'trip-b'),
  (0.07, 47.0, 0, 1020.0, 0, NULL, 1020.0, NULL, 'trip-b');

INSERT INTO ZDRIVESESSIONRECORD VALUES
  (1000.0, 1100.0, 1);

INSERT INTO ZPOTHOLEACTIONRECORD VALUES
  ('manual_report', 'pending_upload', NULL, 1015.0);

INSERT INTO ZUPLOADBATCH VALUES
  ('succeeded', 2, 2, 0, 1100.0);
SQL

"$ROOT_DIR/scripts/local-ios-quality-report.sh" "$STORE_PATH" > "$THIRD_OUTPUT"

require_output "$THIRD_OUTPUT" 'Since last report'
require_output "$THIRD_OUTPUT" 'Road samples \(total\)[[:space:]]+\+3[[:space:]]+\(was 4, now 7\)'
require_output "$THIRD_OUTPUT" 'Accepted samples[[:space:]]+\+3[[:space:]]+\(was 3, now 6\)'
require_output "$THIRD_OUTPUT" 'Sensor pothole candidates[[:space:]]+\+1[[:space:]]+\(was 1, now 2\)'
require_output "$THIRD_OUTPUT" 'Grouped trips[[:space:]]+\+1[[:space:]]+\(was 2, now 3\)'
require_output "$THIRD_OUTPUT" 'Manual pothole marks[[:space:]]+\+1[[:space:]]+\(was 2, now 3\)'
require_output "$THIRD_OUTPUT" 'Upload batches succeeded[[:space:]]+\+1[[:space:]]+\(was 1, now 2\)'
reject_output "$THIRD_OUTPUT" 'baseline'

# --- --no-snapshot-update should preserve the prior snapshot ---
SNAPSHOT_BEFORE_BYTES="$(wc -c < "$SNAPSHOT_PATH")"
SNAPSHOT_BEFORE_HASH="$(shasum "$SNAPSHOT_PATH" | awk '{ print $1 }')"

# Add data that we expect to NOT change the snapshot.
sqlite3 "$STORE_PATH" <<'SQL'
INSERT INTO ZREADINGRECORD VALUES
  (0.05, 50.0, 0, 2000.0, 0, NULL, 2000.0, NULL, 'trip-c');
SQL

NO_UPDATE_OUTPUT="$TMP_DIR/report-no-update.txt"
"$ROOT_DIR/scripts/local-ios-quality-report.sh" --no-snapshot-update "$STORE_PATH" > "$NO_UPDATE_OUTPUT"

SNAPSHOT_AFTER_HASH="$(shasum "$SNAPSHOT_PATH" | awk '{ print $1 }')"

if [[ "$SNAPSHOT_BEFORE_HASH" != "$SNAPSHOT_AFTER_HASH" ]]; then
  echo "Snapshot was updated despite --no-snapshot-update" >&2
  exit 1
fi

require_output "$NO_UPDATE_OUTPUT" 'Road samples \(total\)[[:space:]]+\+1[[:space:]]+\(was 7, now 8\)'

# --- --reset-snapshot should put us back into baseline mode ---
RESET_OUTPUT="$TMP_DIR/report-reset.txt"
"$ROOT_DIR/scripts/local-ios-quality-report.sh" --reset-snapshot "$STORE_PATH" > "$RESET_OUTPUT"

require_output "$RESET_OUTPUT" 'No prior snapshot at'
require_output "$RESET_OUTPUT" 'baseline'

# --- Custom snapshot path is honored ---
CUSTOM_SNAPSHOT="$TMP_DIR/custom.snapshot"
CUSTOM_OUTPUT="$TMP_DIR/report-custom.txt"
"$ROOT_DIR/scripts/local-ios-quality-report.sh" --snapshot-file "$CUSTOM_SNAPSHOT" "$STORE_PATH" > "$CUSTOM_OUTPUT"

if [[ ! -f "$CUSTOM_SNAPSHOT" ]]; then
  echo "Expected custom snapshot at $CUSTOM_SNAPSHOT" >&2
  exit 1
fi

echo "local-ios-quality-report smoke passed"
