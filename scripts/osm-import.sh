#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${DATABASE_URL:?DATABASE_URL must be set}"

SNAPSHOT_URL="${SNAPSHOT_URL:-https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf}"
WORKDIR="${WORKDIR:-/tmp/roadsense-osm}"
OSM_FILE="${WORKDIR}/nova-scotia.osm.pbf"

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

if ! psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('ref.municipalities') IS NOT NULL"; then
    echo "Unable to verify ref.municipalities" >&2
    exit 1
fi

if [[ "$(psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM ref.municipalities")" == "0" ]]; then
    echo "ref.municipalities is empty; import StatCan municipality boundaries before running osm-import.sh" >&2
    exit 1
fi

echo "→ Downloading OSM snapshot"
curl -fsSL -o "${OSM_FILE}" "${SNAPSHOT_URL}"

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
