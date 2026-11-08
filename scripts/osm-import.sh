#!/usr/bin/env bash
#
# Refresh the road network from an OSM snapshot:
#   download PBF → osm2pgsql → road_segments_staging → sanity checks →
#   apply_road_segment_refresh() → finalize_road_segment_refresh() → refresh views.
#
# Usage:
#   DATABASE_URL=postgres://... REGION_KEY=nova-scotia scripts/osm-import.sh [--confirm]
#
# The refresh replaces the LIVE road network, so the script asks for an
# interactive "yes" unless --confirm (or --yes) is passed.
#
# Safety checks before the live tables are touched:
#   * ref.municipalities exists, is non-empty, and every row belongs to the
#     requested region's PRUID (catches a REGION_KEY / boundary-load mismatch).
#   * For a non-local database, REGION_KEY must equal ROADSENSE_PRODUCTION_REGION_KEY
#     (default nova-scotia).
#   * At least OSM_MIN_TAGGED_PERCENT (default 80) of staged segments fall inside
#     a municipality polygon (catches a PBF for the wrong region).
#   * apply_road_segment_refresh() itself refuses an empty or >50%-smaller
#     staging table (migration 20260702121000).
#
# The refresh and finalize_road_segment_refresh() (rematch, full recompute,
# contributor marks, pothole re-anchoring) run in one transaction: if any step
# fails, the live network is left unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/canada-region-config.sh
source "${SCRIPT_DIR}/canada-region-config.sh"
# shellcheck source=scripts/lib/pg-env.sh
source "${SCRIPT_DIR}/lib/pg-env.sh"

CONFIRM=0
for arg in "$@"; do
    case "$arg" in
        --confirm|--yes)
            CONFIRM=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: DATABASE_URL=... REGION_KEY=... $0 [--confirm]" >&2
            exit 2
            ;;
    esac
done

# Connection details reach psql/osm2pgsql through libpq PG* variables, never
# argv: imports run for hours, and argv is visible to every user via `ps`.
roadsense_pg_env_from_database_url
export PGAPPNAME="${PGAPPNAME:-roadsense-osm-import}"

REGION_KEY="${REGION_KEY:-nova-scotia}"
roadsense_load_region_config "${REGION_KEY}"

SNAPSHOT_URL="${SNAPSHOT_URL:-${ROAD_SENSE_GEOFABRIK_URL}}"
WORKDIR="${WORKDIR:-/tmp/roadsense-osm/${ROAD_SENSE_REGION_KEY}}"
OSM_FILE="${OSM_FILE:-${WORKDIR}/${ROAD_SENSE_GEOFABRIK_SLUG}.osm.pbf}"
OSM_MIN_TAGGED_PERCENT="${OSM_MIN_TAGGED_PERCENT:-80}"
PRODUCTION_REGION_KEY="${ROADSENSE_PRODUCTION_REGION_KEY:-nova-scotia}"

if [[ ! "${OSM_MIN_TAGGED_PERCENT}" =~ ^[0-9]+$ ]] || (( OSM_MIN_TAGGED_PERCENT > 100 )); then
    echo "OSM_MIN_TAGGED_PERCENT must be an integer from 0 to 100" >&2
    exit 2
fi

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_cmd curl
require_cmd osm2pgsql
require_cmd psql

db() {
    psql -X -v ON_ERROR_STOP=1 "$@"
}

db_value() {
    psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"
}

mkdir -p "${WORKDIR}"

echo "→ Import region: ${ROAD_SENSE_REGION_NAME} (PRUID ${ROAD_SENSE_REGION_PRUID})"
echo "→ Target: ${ROADSENSE_DB_URL_REDACTED}"

if ! roadsense_is_local_host "${PGHOST}" && [[ "${ROAD_SENSE_REGION_KEY}" != "${PRODUCTION_REGION_KEY}" ]]; then
    echo "REGION_KEY=${ROAD_SENSE_REGION_KEY} does not match the production region '${PRODUCTION_REGION_KEY}' for non-local host ${PGHOST}." >&2
    echo "Set ROADSENSE_PRODUCTION_REGION_KEY explicitly if the deployed region has changed." >&2
    exit 1
fi

municipalities_exist="$(db_value "SELECT to_regclass('ref.municipalities') IS NOT NULL")"
if [[ "${municipalities_exist}" != "t" ]]; then
    echo "ref.municipalities is missing (query returned '${municipalities_exist}'); run scripts/load-municipalities.sh first" >&2
    exit 1
fi

region_counts="$(db_value "SELECT count(*) || ' ' || count(*) FILTER (WHERE pruid IS DISTINCT FROM '${ROAD_SENSE_REGION_PRUID}') FROM ref.municipalities")"
if [[ ! "${region_counts}" =~ ^[0-9]+\ [0-9]+$ ]]; then
    echo "Unable to read ref.municipalities counts (query returned '${region_counts}')" >&2
    exit 1
fi
municipality_count="${region_counts% *}"
foreign_municipalities="${region_counts#* }"
if [[ "${municipality_count}" == "0" ]]; then
    echo "ref.municipalities is empty; import StatCan municipality boundaries before running osm-import.sh" >&2
    exit 1
fi
if [[ "${foreign_municipalities}" != "0" ]]; then
    echo "ref.municipalities has ${foreign_municipalities} of ${municipality_count} rows outside PRUID ${ROAD_SENSE_REGION_PRUID} (${ROAD_SENSE_REGION_NAME})." >&2
    echo "The loaded boundaries do not match REGION_KEY=${ROAD_SENSE_REGION_KEY}; reload them with scripts/load-municipalities.sh." >&2
    exit 1
fi

if [[ "${CONFIRM}" -ne 1 ]]; then
    echo "" >&2
    echo "############################################################" >&2
    echo "# WARNING: this script ends by calling apply_road_segment_refresh()," >&2
    echo "# which replaces the LIVE road network on ${PGHOST} from staged data." >&2
    echo "############################################################" >&2
    echo "" >&2
    if [[ -t 0 ]]; then
        read -r -p "Type 'yes' to continue: " reply
        if [[ "${reply}" != "yes" ]]; then
            echo "Aborted." >&2
            exit 1
        fi
    else
        echo "Refusing to run non-interactively without --confirm (or --yes)." >&2
        exit 1
    fi
fi

echo "→ Downloading OSM snapshot"
curl -fsSL -o "${OSM_FILE}" "${SNAPSHOT_URL}"

echo "→ Importing raw OSM ways/nodes via osm2pgsql flex output"
# Only the database name goes on argv; host, user and password come from
# the PG* environment set above.
osm2pgsql \
    --database="${PGDATABASE}" \
    --slim \
    --create \
    --output=flex \
    --schema=osm \
    --middle-schema=osm \
    --style="${SCRIPT_DIR}/osm2pgsql-style.lua" \
    "${OSM_FILE}"

echo "→ Preparing OSM feature-node indexes"
db -f "${SCRIPT_DIR}/index-osm-nodes.sql"

echo "→ Clearing staging table"
db -c "TRUNCATE road_segments_staging"

echo "→ Segmentizing ways into road_segments_staging"
db -f "${SCRIPT_DIR}/segmentize.sql"

echo "→ Tagging municipalities"
db -f "${SCRIPT_DIR}/tag-municipalities.sql"

echo "→ Tagging derived road features"
db -f "${SCRIPT_DIR}/tag-features.sql"

echo "→ Checking staged segments against the region boundaries"
staged_counts="$(db_value "SELECT count(*) || ' ' || count(*) FILTER (WHERE municipality IS NOT NULL) FROM road_segments_staging")"
if [[ ! "${staged_counts}" =~ ^[0-9]+\ [0-9]+$ ]]; then
    echo "Unable to read road_segments_staging counts (query returned '${staged_counts}')" >&2
    exit 1
fi
staged_total="${staged_counts% *}"
staged_tagged="${staged_counts#* }"
if [[ "${staged_total}" == "0" ]]; then
    echo "road_segments_staging is empty after segmentizing; the snapshot produced no roads. Live network untouched." >&2
    exit 1
fi
tagged_percent=$(( staged_tagged * 100 / staged_total ))
echo "  ${staged_tagged}/${staged_total} staged segments (${tagged_percent}%) fall inside ${ROAD_SENSE_REGION_NAME} municipalities"
if (( tagged_percent < OSM_MIN_TAGGED_PERCENT )); then
    echo "Only ${tagged_percent}% of staged segments are inside ${ROAD_SENSE_REGION_NAME} municipalities (minimum ${OSM_MIN_TAGGED_PERCENT}%)." >&2
    echo "The snapshot ${SNAPSHOT_URL} probably does not match REGION_KEY=${ROAD_SENSE_REGION_KEY}. Live network untouched." >&2
    exit 1
fi

echo "→ Applying staged refresh and finalizing it (one transaction)"
# finalize_road_segment_refresh() (migration 20261108090000) rematches retained
# readings, recomputes every segment with readings or an aggregate, rebuilds
# contributor marks and re-anchors open potholes. It must run in the same
# transaction as the merge, or public scores stay on the wrong pavement.
db --single-transaction <<'SQL'
SELECT * FROM apply_road_segment_refresh();
SELECT finalize_road_segment_refresh();
SQL

echo "→ Refreshing public materialized views"
db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv;"
db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv;"

echo "→ Refresh complete. Segment count:"
db -c "SELECT count(*) AS segment_count FROM road_segments;"
