#!/usr/bin/env bash
#
# Read-mostly API smoke for any environment, including production:
#   /health, /health/deep, /stats, /top-potholes contracts, plus one
#   upload-readings round trip and its duplicate replay.
#
# Leaves no public data behind: the uploaded reading is deliberately
# low-quality (speed below the 15 km/h ingest floor), so ingest_reading_batch
# soft-rejects it. No readings, aggregates, contributor marks or potholes are
# written; only the batch's processed_batches row (needed for the duplicate
# check) and the per-device rate-limit counter. When DATABASE_URL is set
# (local runs), the processed_batches row is deleted on exit.
#
# Usage:
#   FUNCTIONS_BASE_URL=https://api.nsroadsense.ca/functions/v1 \
#   PUBLIC_API_KEY=... [EXPECTED_COMMIT=<git sha>] scripts/api-smoke.sh
#
# EXPECTED_COMMIT, when set, must match the `commit` field of /health.
# DEEP_HEALTH_WAIT_SECONDS (default 180) bounds how long a 503 "degraded"
# /health/deep is re-polled after a deploy; see the comment at that check.
#
# Point it at https://api.nsroadsense.ca/functions/v1, never the Railway
# origin: with REQUIRE_ORIGIN_AUTH=true the origin answers 403 except /health.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL:-http://127.0.0.1:54321/functions/v1}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
PUBLIC_API_KEY="${PUBLIC_API_KEY:-}"
API_KEY="${PUBLIC_API_KEY:-$SUPABASE_ANON_KEY}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-}"

# Stable, clearly-synthetic device token reused by every smoke run, so the
# smoke can never register a new "unique contributor". Must be a UUIDv4.
SMOKE_DEVICE_TOKEN="${SMOKE_DEVICE_TOKEN:-00000000-0000-4000-8000-000000000000}"

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

HAS_DB=0
PSQL_BIN="${PSQL_BIN:-psql}"
if [[ -n "${DATABASE_URL:-}" ]]; then
  # shellcheck source=scripts/lib/pg-env.sh
  source "${SCRIPT_DIR}/lib/pg-env.sh"
  # Credentials reach psql through PG* variables, never argv.
  roadsense_pg_env_from_database_url
  if command -v "${PSQL_BIN}" >/dev/null 2>&1; then
    HAS_DB=1
  fi
fi

tmpdir="$(mktemp -d)"

cleanup() {
  local exit_code=$?
  if [[ "${HAS_DB}" -eq 1 && -n "${SMOKE_BATCH_ID:-}" ]]; then
    echo "→ Removing smoke batch ${SMOKE_BATCH_ID} from processed_batches"
    if ! "${PSQL_BIN}" -X -q -v ON_ERROR_STOP=1 -v batch_id="${SMOKE_BATCH_ID}" <<'SQL'
DELETE FROM readings WHERE batch_id = :'batch_id'::UUID;
DELETE FROM processed_batches WHERE batch_id = :'batch_id'::UUID;
SQL
    then
      echo "  cleanup query failed; the smoke batch row may remain" >&2
      exit_code=1
    fi
  fi
  rm -rf "${tmpdir}"
  exit "${exit_code}"
}
trap cleanup EXIT

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

  # The production gateway requires the apikey on every route, including
  # /health; sending it unconditionally also works against local stacks
  # where /health is open.
  curl_args+=(
    -H "Authorization: Bearer ${API_KEY}"
    -H "apikey: ${API_KEY}"
  )

  if [[ -n "${body_file}" ]]; then
    curl_args+=(
      -H "content-type: application/json"
      --data @"${body_file}"
    )
  fi

  curl "${curl_args[@]}" "${url}"
}

SMOKE_BATCH_ID="$(request_id | sed 's/^smoke-//')"

python3 - "${SMOKE_DEVICE_TOKEN}" "${SMOKE_BATCH_ID}" <<'PY' > "${tmpdir}/upload.json"
import json
import sys
from datetime import datetime, timezone

payload = {
    "batch_id": sys.argv[2],
    "device_token": sys.argv[1],
    "client_sent_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "client_app_version": "api-smoke",
    "client_os_version": "macOS",
    "readings": [
        {
            "lat": 44.6488,
            "lng": -63.5752,
            "roughness_rms": 0.47,
            # Below the 15 km/h ingest floor: soft-rejected as low_quality,
            # so nothing public is written.
            "speed_kmh": 5.0,
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

python3 - "${tmpdir}/health.json" "${EXPECTED_COMMIT}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

# /health is the lite liveness probe — process is up, no DB roundtrip.
# Use /health/deep for the DB check below.
assert payload["status"] == "ok", payload

expected_commit = sys.argv[2]
if expected_commit:
    assert payload.get("commit") == expected_commit, (
        "deployed commit %r != expected %r" % (payload.get("commit"), expected_commit)
    )
PY

# /health/deep answers 503 "degraded" when a scheduler job is stale or failing.
# Right after a deploy the new process may not have run its jobs yet, so poll
# for up to DEEP_HEALTH_WAIT_SECONDS. A 503 whose non-ok jobs are all
# "pending" is accepted at the deadline; stale/failing jobs or an unreachable
# database fail the smoke.
classify_deep_health() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

status_code, path = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (OSError, ValueError):
    print("bad")
    sys.exit(0)
if not isinstance(payload, dict) or payload.get("db") != "reachable":
    print("bad")
elif status_code == "200" and payload.get("status") == "ok":
    print("ok")
elif status_code == "503" and payload.get("status") == "degraded":
    scheduler = payload.get("scheduler") or {}
    jobs = scheduler.get("jobs") or {}
    statuses = {str((job or {}).get("status")) for job in jobs.values()}
    if scheduler.get("status") != "unavailable" and statuses <= {"ok", "pending"}:
        print("pending")
    else:
        print("bad")
else:
    print("bad")
PY
}

DEEP_HEALTH_WAIT_SECONDS="${DEEP_HEALTH_WAIT_SECONDS:-180}"
if [[ ! "${DEEP_HEALTH_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "DEEP_HEALTH_WAIT_SECONDS must be whole seconds." >&2
  exit 1
fi
deep_deadline=$((SECONDS + DEEP_HEALTH_WAIT_SECONDS))
deep_health_note="db reachable"
while true; do
  deep_health_status="$(request GET "${FUNCTIONS_BASE_URL}/health/deep" "" "${tmpdir}/health-deep.json")" || deep_health_status="000"
  deep_state="$(classify_deep_health "${deep_health_status}" "${tmpdir}/health-deep.json")"
  if [[ "${deep_state}" == "ok" ]]; then
    break
  fi
  if (( SECONDS >= deep_deadline )); then
    if [[ "${deep_state}" == "pending" ]]; then
      deep_health_note="db reachable; scheduler jobs still pending after deploy"
      break
    fi
    echo "health/deep check failed with HTTP ${deep_health_status}" >&2
    cat "${tmpdir}/health-deep.json" >&2
    exit 1
  fi
  echo "  /health/deep: HTTP ${deep_health_status} (${deep_state}); retrying in 15s" >&2
  sleep 15
done

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
# The smoke reading must never be accepted: an accepted reading would
# change public aggregates.
assert response_payload["accepted"] == 0, response_payload
assert response_payload["rejected_reasons"].get("low_quality") == 1, response_payload
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
echo "  /health: ok (liveness${EXPECTED_COMMIT:+, commit ${EXPECTED_COMMIT}})"
echo "  /health/deep: ok (${deep_health_note})"
echo "  /stats: contract ok"
echo "  /top-potholes: contract ok"
echo "  /upload-readings: ${summary}"
echo "  /upload-readings duplicate replay: ok"
