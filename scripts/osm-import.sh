#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/canada-region-config.sh"

: "${DATABASE_URL:?DATABASE_URL must be set}"

REGION_KEY="${REGION_KEY:-nova-scotia}"
roadsense_load_region_config "${REGION_KEY}"

SNAPSHOT_URL="${SNAPSHOT_URL:-${ROAD_SENSE_GEOFABRIK_URL}}"
WORKDIR="${WORKDIR:-/tmp/roadsense-osm/${ROAD_SENSE_REGION_KEY}}"
OSM_FILE="${OSM_FILE:-${WORKDIR}/${ROAD_SENSE_GEOFABRIK_SLUG}.osm.pbf}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_cmd curl
require_cmd osm2pgsql
require_cmd psql

mkdir -p "${WORKDIR}"

# Verify a cached pbf against Geofabrik's published .md5 before reusing it.
# osm2pgsql fails opaquely on truncated files ("PBF error: unexpected EOF") and
# the natural debugging path eats 20+ minutes. If the checksum file isn't
# fetchable (Geofabrik is occasionally proxied/502s) we fall back to the byte-
# count heuristic below rather than blocking the import.
verify_cached_pbf() {
    local pbf="$1"
    local md5_url="${SNAPSHOT_URL}.md5"

    [[ -f "${pbf}" ]] || return 1

    local published
    published="$(curl -fsSL --max-time 30 "${md5_url}" 2>/dev/null | awk '{print $1}')"
    if [[ -n "${published}" ]]; then
        local local_md5
        if command -v md5sum >/dev/null 2>&1; then
            local_md5="$(md5sum "${pbf}" | awk '{print $1}')"
        else
            local_md5="$(md5 -q "${pbf}")"
        fi
        if [[ "${local_md5}" == "${published}" ]]; then
            echo "  cached pbf md5 matches Geofabrik (${published:0:12}…)"
            return 0
        fi
        echo "  cached pbf md5 mismatch (have ${local_md5:0:12}…, want ${published:0:12}…) — redownloading" >&2
        return 1
    fi

    # No checksum reachable — fall back to a sanity check on file size. A
    # truncated file is usually orders of magnitude smaller than a complete
    # one. Reject anything under 10 MB.
    local size_bytes
    size_bytes="$(stat -f%z "${pbf}" 2>/dev/null || stat -c%s "${pbf}")"
    if (( size_bytes < 10_000_000 )); then
        echo "  cached pbf is ${size_bytes} bytes — looks truncated, redownloading" >&2
        return 1
    fi
    echo "  cached pbf size=${size_bytes} bytes (no checksum available, accepting)"
    return 0
}

echo "→ Import region: ${ROAD_SENSE_REGION_NAME}"

if ! psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('ref.municipalities') IS NOT NULL"; then
    echo "Unable to verify ref.municipalities" >&2
    exit 1
fi

if [[ "$(psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM ref.municipalities")" == "0" ]]; then
    echo "ref.municipalities is empty; import StatCan municipality boundaries before running osm-import.sh" >&2
    exit 1
fi

echo "→ Resolving OSM snapshot (cache: ${OSM_FILE})"
if verify_cached_pbf "${OSM_FILE}"; then
    echo "  using cached pbf"
else
    echo "  downloading from ${SNAPSHOT_URL}"
    curl -fSL -o "${OSM_FILE}.partial" "${SNAPSHOT_URL}"
    mv "${OSM_FILE}.partial" "${OSM_FILE}"
    if ! verify_cached_pbf "${OSM_FILE}"; then
        echo "downloaded pbf failed verification — aborting before osm2pgsql wastes time" >&2
        exit 1
    fi
fi

echo "→ Importing raw OSM ways/nodes via osm2pgsql flex output"
osm2pgsql \
    --database="${DATABASE_URL}" \
    --slim \
    --create \
    --output=flex \
    --schema=osm \
    --middle-schema=osm \
    --style="${SCRIPT_DIR}/osm2pgsql-style.lua" \
    "${OSM_FILE}"

echo "→ Preparing OSM feature-node indexes"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -f "${SCRIPT_DIR}/index-osm-nodes.sql"

echo "→ Clearing staging table"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -c "TRUNCATE road_segments_staging"

echo "→ Segmentizing ways into road_segments_staging"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -f "${SCRIPT_DIR}/segmentize.sql"

echo "→ Tagging municipalities"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -f "${SCRIPT_DIR}/tag-municipalities.sql"

echo "→ Tagging derived road features"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -f "${SCRIPT_DIR}/tag-features.sql"

echo "→ Applying staged refresh into road_segments"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -c "SELECT apply_road_segment_refresh();"

echo "→ Refresh complete. Segment count:"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -c "SELECT count(*) AS segment_count FROM road_segments;"
