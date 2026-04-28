#!/usr/bin/env bash
set -euo pipefail

FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL:-http://127.0.0.1:54321/functions/v1}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
PUBLIC_API_KEY="${PUBLIC_API_KEY:-}"
API_KEY="${PUBLIC_API_KEY:-$SUPABASE_ANON_KEY}"

if [[ -z "${API_KEY}" ]]; then
  echo "PUBLIC_API_KEY or SUPABASE_ANON_KEY is required." >&2
  echo "Example:" >&2
  echo "  export PUBLIC_API_KEY=..." >&2
  echo "  export FUNCTIONS_BASE_URL=http://127.0.0.1:54321/functions/v1" >&2
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
print(f"smoke-{uuid.uuid4()}")
PY
}

request() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  local response_file="$4"

  local curl_args=(
    -sS
    -X "${method}"
    -o "${response_file}"
    -w "%{http_code}"
    -H "x-request-id: $(request_id)"
  )

  if [[ "${url}" != */health ]]; then
    curl_args+=(
      -H "Authorization: Bearer ${API_KEY}"
      -H "apikey: ${API_KEY}"
    )
  fi

  if [[ -n "${body_file}" ]]; then
    curl_args+=(
      -H "content-type: application/json"
      --data @"${body_file}"
    )
  fi

  curl "${curl_args[@]}" "${url}"
}

python3 - <<'PY' > "${tmpdir}/upload.json"
import json
import uuid
from datetime import datetime, timezone

payload = {
    "batch_id": str(uuid.uuid4()),
    "device_token": str(uuid.uuid4()),
    "client_sent_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "client_app_version": "smoke-script (local)",
    "client_os_version": "macOS",
    "readings": [
        {
            "lat": 44.6488,
            "lng": -63.5752,
            "roughness_rms": 0.47,
            "speed_kmh": 52.0,
            "heading": 184.5,
            "gps_accuracy_m": 6.5,
            "recorded_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "is_pothole": False,
            "pothole_magnitude": None,
        }
    ],
}

print(json.dumps(payload))
PY

health_status="$(request GET "${FUNCTIONS_BASE_URL}/health" "" "${tmpdir}/health.json")"
if [[ "${health_status}" != "200" ]]; then
  echo "health check failed with HTTP ${health_status}" >&2
  cat "${tmpdir}/health.json" >&2
  exit 1
fi

python3 - "${tmpdir}/health.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

# /health is the lite liveness probe — process is up, no DB roundtrip.
# Use /health/deep for the DB check below.
assert payload["status"] == "ok", payload
PY

deep_health_status="$(request GET "${FUNCTIONS_BASE_URL}/health/deep" "" "${tmpdir}/health-deep.json")"
if [[ "${deep_health_status}" != "200" ]]; then
  echo "health/deep check failed with HTTP ${deep_health_status}" >&2
  cat "${tmpdir}/health-deep.json" >&2
  exit 1
fi

python3 - "${tmpdir}/health-deep.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

assert payload["status"] == "ok", payload
assert payload["db"] == "reachable", payload
PY

stats_status="$(request GET "${FUNCTIONS_BASE_URL}/stats" "" "${tmpdir}/stats.json")"
if [[ "${stats_status}" != "200" ]]; then
  echo "stats check failed with HTTP ${stats_status}" >&2
  cat "${tmpdir}/stats.json" >&2
  exit 1
fi

python3 - "${tmpdir}/stats.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

required = {
    "total_km_mapped",
    "total_readings",
    "segments_scored",
    "active_potholes",
    "municipalities_covered",
    "generated_at",
}

missing = required - payload.keys()
assert not missing, missing
PY

top_potholes_status="$(request GET "${FUNCTIONS_BASE_URL}/top-potholes?limit=5" "" "${tmpdir}/top-potholes.json")"
if [[ "${top_potholes_status}" != "200" ]]; then
  echo "top-potholes check failed with HTTP ${top_potholes_status}" >&2
  cat "${tmpdir}/top-potholes.json" >&2
  exit 1
fi

python3 - "${tmpdir}/top-potholes.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

assert isinstance(payload.get("potholes"), list), payload
for row in payload["potholes"]:
    for key in [
        "id",
        "lat",
        "lng",
        "magnitude",
        "confirmation_count",
        "first_reported_at",
        "last_confirmed_at",
        "status",
        "segment_id",
    ]:
        assert key in row, row
PY

upload_status="$(request POST "${FUNCTIONS_BASE_URL}/upload-readings" "${tmpdir}/upload.json" "${tmpdir}/upload-response.json")"
if [[ "${upload_status}" != "200" ]]; then
  echo "upload-readings failed with HTTP ${upload_status}" >&2
  cat "${tmpdir}/upload-response.json" >&2
  exit 1
fi

python3 - "${tmpdir}/upload.json" "${tmpdir}/upload-response.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    request_payload = json.load(fh)
with open(sys.argv[2], "r", encoding="utf-8") as fh:
    response_payload = json.load(fh)

assert response_payload["batch_id"] == request_payload["batch_id"], response_payload
assert isinstance(response_payload["accepted"], int), response_payload
assert isinstance(response_payload["rejected"], int), response_payload
assert isinstance(response_payload["duplicate"], bool), response_payload
assert isinstance(response_payload["rejected_reasons"], dict), response_payload
assert response_payload["accepted"] + response_payload["rejected"] == len(request_payload["readings"]), response_payload
PY

duplicate_status="$(request POST "${FUNCTIONS_BASE_URL}/upload-readings" "${tmpdir}/upload.json" "${tmpdir}/duplicate-response.json")"
if [[ "${duplicate_status}" != "200" ]]; then
  echo "duplicate upload replay failed with HTTP ${duplicate_status}" >&2
  cat "${tmpdir}/duplicate-response.json" >&2
  exit 1
fi

python3 - "${tmpdir}/upload-response.json" "${tmpdir}/duplicate-response.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    first = json.load(fh)
with open(sys.argv[2], "r", encoding="utf-8") as fh:
    second = json.load(fh)

assert second["duplicate"] is True, second
assert second["accepted"] == first["accepted"], (first, second)
assert second["rejected"] == first["rejected"], (first, second)
assert second["rejected_reasons"] == first["rejected_reasons"], (first, second)
PY

summary="$(python3 - "${tmpdir}/upload-response.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

print(f"accepted={payload['accepted']} rejected={payload['rejected']} duplicate={payload['duplicate']}")
PY
)"

echo "API smoke passed against ${FUNCTIONS_BASE_URL}"
echo "  /health: ok (liveness)"
echo "  /health/deep: ok (db reachable)"
echo "  /stats: contract ok"
echo "  /top-potholes: contract ok"
echo "  /upload-readings: ${summary}"
echo "  /upload-readings duplicate replay: ok"
