#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

TMPDIR_PATH="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_PATH}"' EXIT

response_file="${TMPDIR_PATH}/response.txt"
response_code=""

log() {
  printf '→ %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "$1 is required."
  fi
}

request() {
  local url="$1"
  shift

  response_code="$(
    curl -sS --max-time 15 -o "${response_file}" -w "%{http_code}" "$@" "${url}" || true
  )"
}

print_response_body() {
  if [[ -s "${response_file}" ]]; then
    cat "${response_file}" >&2
  fi
}

project_id="$(
  awk -F' *= *' '/^project_id *=/ { gsub(/"/, "", $2); print $2; exit }' supabase/config.toml
)"
api_port="$(
  awk -F' *= *' '
    /^\[api\]$/ { in_api=1; next }
    /^\[/ { in_api=0 }
    in_api && /^port *=/ { gsub(/"/, "", $2); print $2; exit }
  ' supabase/config.toml
)"

project_id="${project_id:-roadsense-ns}"
api_port="${api_port:-54321}"
base_url="http://127.0.0.1:${api_port}"
functions_base_url="${base_url}/functions/v1"
edge_container="supabase_edge_runtime_${project_id}"

local_hostname=""
if command -v scutil >/dev/null 2>&1; then
  local_hostname="$(scutil --get LocalHostName 2>/dev/null || true)"
fi

anon_key="${SUPABASE_ANON_KEY:-}"
if [[ -z "${anon_key}" ]]; then
  secrets_file="${ROOT_DIR}/ios/Config/RoadSenseNS.Local.secrets.xcconfig"
  if [[ -f "${secrets_file}" ]]; then
    anon_key="$(
      awk -F' *= *' '/^SUPABASE_ANON_KEY *=/ { print $2; exit }' "${secrets_file}"
    )"
  fi
fi

functions_env_file="${ROOT_DIR}/supabase/functions/.env"

require_cmd supabase
require_cmd docker
require_cmd curl
require_cmd awk

ensure_local_function_secrets() {
  if [[ ! -f "${functions_env_file}" ]]; then
    fail "missing ${functions_env_file}. Add TOKEN_PEPPER for local Edge Functions."
  fi

  if ! awk -F' *= *' '/^TOKEN_PEPPER *=/ && length($2) > 0 { found=1 } END { exit(found ? 0 : 1) }' "${functions_env_file}"; then
    fail "${functions_env_file} is missing TOKEN_PEPPER."
  fi
}

ensure_edge_runtime_running() {
  if ! docker container inspect "${edge_container}" >/dev/null 2>&1; then
    fail "edge runtime container ${edge_container} does not exist after 'supabase start'."
  fi

  local status
  status="$(docker inspect -f '{{.State.Status}}' "${edge_container}")"
  if [[ "${status}" != "running" ]]; then
    log "starting ${edge_container} (${status})"
    docker start "${edge_container}" >/dev/null
  fi
}

restart_edge_runtime() {
  log "restarting ${edge_container}"
  docker restart "${edge_container}" >/dev/null
}

wait_for_health() {
  local attempts="${1:-20}"

  for (( attempt=1; attempt<=attempts; attempt++ )); do
    request "${functions_base_url}/health"
    if [[ "${response_code}" == "200" ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

tiles_smoke_check() {
  if [[ -z "${anon_key}" ]]; then
    return 2
  fi

  request "${functions_base_url}/tiles/0/0/0.mvt?apikey=${anon_key}"
  [[ "${response_code}" == "200" || "${response_code}" == "204" ]]
}

print_edge_logs() {
  docker logs --tail 80 "${edge_container}" >&2 || true
}

log "starting local Supabase stack"
ensure_local_function_secrets
if ! supabase start >"${TMPDIR_PATH}/supabase-start.log" 2>&1; then
  cat "${TMPDIR_PATH}/supabase-start.log" >&2
  fail "'supabase start' failed."
fi

ensure_edge_runtime_running

if ! wait_for_health; then
  warn "functions health check did not come up after startup; retrying edge runtime"
  restart_edge_runtime
  if ! wait_for_health; then
    print_response_body
    print_edge_logs
    fail "functions health check failed with HTTP ${response_code}."
  fi
fi

tiles_status="skipped"
if tiles_smoke_check; then
  tiles_status="${response_code}"
elif [[ $? -eq 2 ]]; then
  warn "SUPABASE_ANON_KEY not found; skipping tiles smoke check."
else
  warn "tiles smoke check failed with HTTP ${response_code}; retrying edge runtime"
  restart_edge_runtime
  if ! wait_for_health 10; then
    print_response_body
    print_edge_logs
    fail "functions health check failed after edge runtime restart."
  fi

  if ! tiles_smoke_check; then
    print_response_body
    print_edge_logs
    fail "tiles smoke check failed with HTTP ${response_code}."
  fi
  tiles_status="${response_code}"
fi

db_container="supabase_db_${project_id}"

road_segments_count() {
  if ! docker container inspect "${db_container}" >/dev/null 2>&1; then
    return 1
  fi
  docker exec "${db_container}" psql -U postgres -d postgres -At -c \
    "SELECT count(*) FROM road_segments" 2>/dev/null
}

# Without road_segments populated, every reading uploaded by the iOS client
# rejects as `no_segment_match` and lands in unmatched_readings. Surface this
# loudly because the failure mode is invisible from the API surface — health
# checks pass, tiles return 200 — but the heat-map stays blank forever.
#
# WITH_OSM_IMPORT=1 triggers osm-import.sh inline; otherwise we just warn so
# the existing engineer's flow isn't extended by ~5 min on every restart.
maybe_import_osm() {
  local count
  count="$(road_segments_count || true)"
  if [[ -z "${count}" ]]; then
    return 0
  fi

  # 7 is the seed-data fixture count (`Coverage None Road`, etc.). Anything
  # under ~100 means a real OSM import never ran.
  if (( count > 100 )); then
    printf '  road_segments: %s\n' "${count}"
    return 0
  fi

  if [[ "${WITH_OSM_IMPORT:-0}" == "1" ]]; then
    log "road_segments has only ${count} rows — running osm-import.sh"
    local pg_port
    pg_port="$(docker port "${db_container}" 5432/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
    pg_port="${pg_port:-54322}"
    DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${pg_port}/postgres" \
      bash "${ROOT_DIR}/scripts/osm-import.sh"
    count="$(road_segments_count || true)"
    printf '  road_segments: %s (after import)\n' "${count}"
  else
    warn "road_segments has only ${count} rows; readings will reject as no_segment_match."
    warn "Run with WITH_OSM_IMPORT=1 ./scripts/local-backend-up.sh, or:"
    warn "  DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres ./scripts/osm-import.sh"
  fi
}

log "local backend ready"
printf '  API: %s\n' "${base_url}"
printf '  Functions health: ok\n'
printf '  Edge runtime: %s\n' "${edge_container}"
if [[ -n "${local_hostname}" ]]; then
  printf '  Phone URL: http://%s.local:%s\n' "${local_hostname}" "${api_port}"
fi
if [[ "${tiles_status}" != "skipped" ]]; then
  printf '  Tiles: HTTP %s\n' "${tiles_status}"
fi
maybe_import_osm
