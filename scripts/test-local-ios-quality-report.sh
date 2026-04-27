#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STORE_PATH="$TMP_DIR/default.store"
OUTPUT_PATH="$TMP_DIR/report.txt"

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

"$ROOT_DIR/scripts/local-ios-quality-report.sh" "$STORE_PATH" > "$OUTPUT_PATH"

require_output() {
  local pattern="$1"
  if ! grep -Eq "$pattern" "$OUTPUT_PATH"; then
    echo "Missing expected report pattern: $pattern" >&2
    echo "--- report ---" >&2
    cat "$OUTPUT_PATH" >&2
    exit 1
  fi
}

require_output 'total_samples[[:space:]]+4'
require_output 'accepted_samples[[:space:]]+3'
require_output 'pending_upload_samples[[:space:]]+1'
require_output 'endpoint_trimmed_samples[[:space:]]+1'
require_output 'privacy_filtered_samples[[:space:]]+1'
require_output 'sensor_pothole_candidates[[:space:]]+1'
require_output 'grouped_trips[[:space:]]+2'
require_output 'manual_report[[:space:]]+pending_upload[[:space:]]+1'
require_output 'pending_metadata[[:space:]]+1[[:space:]]+2048'

echo "local-ios-quality-report smoke passed"
