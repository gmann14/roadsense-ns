#!/usr/bin/env bash
#
# Replay every accepted, non-trimmed reading from a copied iOS SwiftData
# snapshot back through /functions/v1/upload-readings.
#
# Useful when the server discarded a drive (no_segment_match) and you've
# since populated road_segments with proper coverage.
#
# The server's duplicate-reading detection (device_token_hash + recorded_at +
# 0.5m radius) means rerunning is safe: anything already accepted gets counted
# as a duplicate, anything previously rejected as no_segment_match now lands.

set -euo pipefail

SNAPSHOT="${1:-.context/device-live-latest/Library/Application Support/default.store}"
FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL:-http://127.0.0.1:54321/functions/v1}"
ANON_KEY="${SUPABASE_ANON_KEY:-${NEXT_PUBLIC_SUPABASE_ANON_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}}"
BATCH_SIZE="${BATCH_SIZE:-500}"
DRY_RUN="${DRY_RUN:-0}"

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "snapshot not found: $SNAPSHOT" >&2
  exit 1
fi

DEVICE_TOKEN="$(sqlite3 "$SNAPSHOT" 'SELECT ZTOKEN FROM ZDEVICETOKENRECORD LIMIT 1;')"
if [[ -z "$DEVICE_TOKEN" ]]; then
  echo "no device token found in snapshot" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
JSONL="$TMP_DIR/readings.jsonl"

# Pull every reading the phone collected that wasn't filtered or trimmed,
# in chronological order. Convert Core Data epoch (2001-01-01) to ISO 8601 UTC.
sqlite3 "$SNAPSHOT" <<SQL > "$JSONL"
.mode list
.separator ""
SELECT json_object(
  'lat', ZLATITUDE,
  'lng', ZLONGITUDE,
  'roughness_rms', ZROUGHNESSRMS,
  'speed_kmh', ZSPEEDKMH,
  'heading', ZHEADING,
  'gps_accuracy_m', ZGPSACCURACYM,
  'is_pothole', CASE WHEN ZISPOTHOLE = 1 THEN json('true') ELSE json('false') END,
  'pothole_magnitude', CASE WHEN ZPOTHOLEMAGNITUDE > 0 THEN ZPOTHOLEMAGNITUDE ELSE NULL END,
  'recorded_at', strftime('%Y-%m-%dT%H:%M:%fZ', ZRECORDEDAT + 978307200, 'unixepoch')
)
FROM ZREADINGRECORD
WHERE ZDROPPEDBYPRIVACYZONE = 0
  AND ZENDPOINTTRIMMEDAT IS NULL
ORDER BY ZRECORDEDAT;
SQL

TOTAL_READINGS="$(wc -l < "$JSONL" | tr -d ' ')"
if [[ "$TOTAL_READINGS" -eq 0 ]]; then
  echo "no eligible readings in snapshot" >&2
  exit 0
fi

echo "snapshot:      $SNAPSHOT"
echo "device token:  $DEVICE_TOKEN"
echo "endpoint:      $FUNCTIONS_BASE_URL/upload-readings"
echo "readings:      $TOTAL_READINGS"
echo "batch size:    $BATCH_SIZE"
echo "dry-run:       $DRY_RUN"
echo ""

# Split into batches
split -l "$BATCH_SIZE" "$JSONL" "$TMP_DIR/batch_"

CLIENT_SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
APP_VERSION="0.1.0 (replay)"
OS_VERSION="iOS replay"

TOTAL_ACCEPTED=0
TOTAL_REJECTED=0
TOTAL_DUPLICATE=0

for batch_file in "$TMP_DIR"/batch_*; do
  batch_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  payload_file="$TMP_DIR/payload_$(basename "$batch_file").json"

  # Build the request payload: { batch_id, device_token, client_sent_at, ..., readings: [...] }
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    const lines = fs.readFileSync(path, "utf8").split("\n").filter(Boolean);
    const readings = lines.map((line) => JSON.parse(line));
    const payload = {
      batch_id: process.argv[2],
      device_token: process.argv[3],
      client_sent_at: process.argv[4],
      client_app_version: process.argv[5],
      client_os_version: process.argv[6],
      readings,
    };
    process.stdout.write(JSON.stringify(payload));
  ' "$batch_file" "$batch_id" "$DEVICE_TOKEN" "$CLIENT_SENT_AT" "$APP_VERSION" "$OS_VERSION" > "$payload_file"

  count="$(wc -l < "$batch_file" | tr -d ' ')"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] would POST batch $batch_id ($count readings)"
    continue
  fi

  response_file="$TMP_DIR/response_$(basename "$batch_file").json"
  status="$(curl -s -o "$response_file" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $ANON_KEY" \
    --data-binary "@$payload_file" \
    "$FUNCTIONS_BASE_URL/upload-readings")"

  if [[ "$status" != "200" ]]; then
    echo "  ✗ batch $batch_id ($count readings) HTTP $status: $(cat "$response_file")"
    continue
  fi

  accepted="$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(r.accepted ?? 0));' "$response_file")"
  rejected="$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(r.rejected ?? 0));' "$response_file")"
  duplicate="$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(r.duplicate ?? false));' "$response_file")"
  reasons="$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(JSON.stringify(r.rejected_reasons ?? {}));' "$response_file")"

  TOTAL_ACCEPTED=$((TOTAL_ACCEPTED + accepted))
  TOTAL_REJECTED=$((TOTAL_REJECTED + rejected))
  if [[ "$duplicate" == "true" ]]; then
    TOTAL_DUPLICATE=$((TOTAL_DUPLICATE + 1))
  fi
  echo "  ✓ batch $batch_id ($count readings): accepted=$accepted rejected=$rejected reasons=$reasons"
done

echo ""
echo "=== summary ==="
echo "total readings sent: $TOTAL_READINGS"
echo "accepted:            $TOTAL_ACCEPTED"
echo "rejected:            $TOTAL_REJECTED"
echo "duplicate batches:   $TOTAL_DUPLICATE"
