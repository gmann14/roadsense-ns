#!/usr/bin/env bash
set -euo pipefail

FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL:-http://127.0.0.1:54321/functions/v1}"
DATABASE_URL="${DATABASE_URL:-}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
PSQL_BIN="${PSQL_BIN:-psql}"

SEGMENT_ID="11111111-2222-4333-8444-555555555555"
OSM_WAY_ID="999000001"
SEGMENT_LAT="44.6488"
SEGMENT_LNG="-63.5752"
ZOOM_LEVEL="14"

if [[ -z "${DATABASE_URL}" ]]; then
  echo "DATABASE_URL is required." >&2
  exit 1
fi

if [[ -z "${SUPABASE_ANON_KEY}" ]]; then
  echo "SUPABASE_ANON_KEY is required." >&2
  exit 1
fi

if ! command -v "${PSQL_BIN}" >/dev/null 2>&1; then
  echo "psql is required." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

request_id() {
  python3 - <<'PY'
import uuid
print(f"seeded-smoke-{uuid.uuid4()}")
PY
}

http_request() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  local response_file="$4"
  local header_file="$5"

  local curl_args=(
    -sS
    -D "${header_file}"
    -o "${response_file}"
    -w "%{http_code}"
    -X "${method}"
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}"
    -H "apikey: ${SUPABASE_ANON_KEY}"
    -H "x-request-id: $(request_id)"
  )

  if [[ -n "${body_file}" ]]; then
    curl_args+=(
      -H "content-type: application/json"
      --data @"${body_file}"
    )
  fi

  curl "${curl_args[@]}" "${url}"
}

db() {
  "${PSQL_BIN}" "${DATABASE_URL}" -v ON_ERROR_STOP=1 "$@"
}

echo "→ Seeding synthetic road segment"
db <<SQL
DELETE FROM readings WHERE segment_id = '${SEGMENT_ID}';
DELETE FROM segment_aggregates WHERE segment_id = '${SEGMENT_ID}';
DELETE FROM pothole_reports WHERE segment_id = '${SEGMENT_ID}';
DELETE FROM road_segments WHERE id = '${SEGMENT_ID}' OR osm_way_id = ${OSM_WAY_ID};

INSERT INTO road_segments (
    id,
    osm_way_id,
    segment_index,
    geom,
    length_m,
    road_name,
    road_type,
    surface_type,
    municipality,
    has_speed_bump,
    has_rail_crossing,
    is_parking_aisle,
    bearing_degrees
) VALUES (
    '${SEGMENT_ID}',
    ${OSM_WAY_ID},
    0,
    ST_GeomFromText('LINESTRING(-63.5752 44.6493, -63.5752 44.6483)', 4326),
    111.0,
    'Smoke Test Rd',
    'residential',
    'paved',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    180.0
);
SQL

echo "→ Building three upload batches against the seeded segment"
python3 - "${tmpdir}" <<'PY'
import json
import pathlib
import sys
import uuid
from datetime import datetime, timedelta, timezone

outdir = pathlib.Path(sys.argv[1])
now = datetime.now(timezone.utc)
roughness = [0.82, 0.91, 1.02]

for idx, rms in enumerate(roughness, start=1):
    payload = {
        "batch_id": str(uuid.uuid4()),
        "device_token": str(uuid.uuid4()),
        "client_sent_at": now.isoformat().replace("+00:00", "Z"),
        "client_app_version": f"seeded-smoke ({idx})",
        "client_os_version": "macOS",
        "readings": [
            {
                "lat": 44.6488,
                "lng": -63.5752,
                "roughness_rms": rms,
                "speed_kmh": 48.0 + idx,
                "heading": 180.0,
                "gps_accuracy_m": 5.0,
                "recorded_at": (now - timedelta(minutes=idx)).isoformat().replace("+00:00", "Z"),
                "is_pothole": False,
                "pothole_magnitude": None,
            }
        ],
    }
    (outdir / f"upload-{idx}.json").write_text(json.dumps(payload), encoding="utf-8")
PY

for idx in 1 2 3; do
  echo "→ Upload batch ${idx}"
  status="$(http_request POST "${FUNCTIONS_BASE_URL}/upload-readings" "${tmpdir}/upload-${idx}.json" "${tmpdir}/upload-${idx}-response.json" "${tmpdir}/upload-${idx}-headers.txt")"
  if [[ "${status}" != "200" ]]; then
    echo "upload ${idx} failed with HTTP ${status}" >&2
    cat "${tmpdir}/upload-${idx}-response.json" >&2
    exit 1
  fi

  python3 - "${tmpdir}/upload-${idx}.json" "${tmpdir}/upload-${idx}-response.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    request_payload = json.load(fh)
with open(sys.argv[2], "r", encoding="utf-8") as fh:
    response_payload = json.load(fh)

assert response_payload["batch_id"] == request_payload["batch_id"], response_payload
assert response_payload["accepted"] == 1, response_payload
assert response_payload["rejected"] == 0, response_payload
assert response_payload["duplicate"] is False, response_payload
assert response_payload["rejected_reasons"] == {}, response_payload
PY
done

echo "→ Refreshing public stats materialized view"
db -c "REFRESH MATERIALIZED VIEW public_stats_mv;"

echo "→ Verifying DB state"
readings_count="$(db -At -c "SELECT COUNT(*) FROM readings WHERE segment_id = '${SEGMENT_ID}';")"
if [[ "${readings_count}" != "3" ]]; then
  echo "expected 3 readings for seeded segment, found ${readings_count}" >&2
  exit 1
fi

db -At <<SQL > "${tmpdir}/aggregate.txt"
SELECT
    total_readings,
    unique_contributors,
    confidence,
    roughness_category
FROM segment_aggregates
WHERE segment_id = '${SEGMENT_ID}';
SQL

python3 - "${tmpdir}/aggregate.txt" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
assert text, "aggregate row missing"
parts = text.split("|")
assert parts[0] == "3", parts
assert parts[1] == "3", parts
assert parts[2] == "medium", parts
assert parts[3] in {"rough", "very_rough"}, parts
PY

echo "→ Fetching segment detail"
segment_status="$(http_request GET "${FUNCTIONS_BASE_URL}/segments/${SEGMENT_ID}" "" "${tmpdir}/segment.json" "${tmpdir}/segment-headers.txt")"
if [[ "${segment_status}" != "200" ]]; then
  echo "segment detail failed with HTTP ${segment_status}" >&2
  cat "${tmpdir}/segment.json" >&2
  exit 1
fi

python3 - "${tmpdir}/segment.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

assert payload["id"] == "11111111-2222-4333-8444-555555555555", payload
assert payload["road_name"] == "Smoke Test Rd", payload
assert payload["aggregate"]["total_readings"] == 3, payload
assert payload["aggregate"]["unique_contributors"] == 3, payload
assert payload["aggregate"]["confidence"] == "medium", payload
PY

echo "→ Fetching refreshed public stats"
stats_status="$(http_request GET "${FUNCTIONS_BASE_URL}/stats" "" "${tmpdir}/stats.json" "${tmpdir}/stats-headers.txt")"
if [[ "${stats_status}" != "200" ]]; then
  echo "stats lookup failed with HTTP ${stats_status}" >&2
  cat "${tmpdir}/stats.json" >&2
  exit 1
fi

python3 - "${tmpdir}/stats.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

assert payload["segments_scored"] >= 1, payload
assert payload["total_readings"] >= 3, payload
assert payload["total_km_mapped"] > 0, payload
PY

read -r tile_x tile_y < <(python3 - "${SEGMENT_LAT}" "${SEGMENT_LNG}" "${ZOOM_LEVEL}" <<'PY'
import math
import sys

lat = float(sys.argv[1])
lng = float(sys.argv[2])
zoom = int(sys.argv[3])
n = 2 ** zoom
x = int((lng + 180.0) / 360.0 * n)
lat_rad = math.radians(lat)
y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
print(x, y)
PY
)

echo "→ Fetching quality tile ${ZOOM_LEVEL}/${tile_x}/${tile_y}.mvt"
tile_status="$(http_request GET "${FUNCTIONS_BASE_URL}/tiles/${ZOOM_LEVEL}/${tile_x}/${tile_y}.mvt" "" "${tmpdir}/tile.mvt" "${tmpdir}/tile-headers.txt")"
if [[ "${tile_status}" != "200" ]]; then
  echo "tile request failed with HTTP ${tile_status}" >&2
  cat "${tmpdir}/tile-headers.txt" >&2
  exit 1
fi

python3 - "${tmpdir}/tile-headers.txt" "${tmpdir}/tile.mvt" <<'PY'
import pathlib
import sys

headers = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").lower()
tile_path = pathlib.Path(sys.argv[2])

assert "content-type: application/vnd.mapbox-vector-tile" in headers, headers
assert tile_path.stat().st_size > 0, tile_path.stat().st_size
PY

echo "Seeded end-to-end smoke passed against ${FUNCTIONS_BASE_URL}"
echo "  segment detail: ok (${SEGMENT_ID})"
echo "  readings inserted: 3"
echo "  aggregate confidence: medium"
echo "  stats refreshed: ok"
echo "  tile emitted: ${ZOOM_LEVEL}/${tile_x}/${tile_y}.mvt"
