#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/canada-region-config.sh"

: "${DATABASE_URL:?DATABASE_URL must be set}"

REGION_KEY="${REGION_KEY:-nova-scotia}"
roadsense_load_region_config "${REGION_KEY}"

STATCAN_CSD_ZIP_URL="${STATCAN_CSD_ZIP_URL:-https://www12.statcan.gc.ca/census-recensement/2011/geo/bound-limit/files-fichiers/lcsd000a25p_e.zip}"
WORKDIR="${WORKDIR:-/tmp/roadsense-statcan/${ROAD_SENSE_REGION_KEY}}"
EXTRACT_DIR="${WORKDIR}/extract"
RAW_TABLE="ref.municipalities_raw"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_cmd curl
require_cmd ogr2ogr
require_cmd ogrinfo
require_cmd psql
require_cmd unzip

mkdir -p "${WORKDIR}"

resolve_gpkg_path() {
    if [[ -n "${STATCAN_GPKG_PATH:-}" ]]; then
        printf '%s\n' "${STATCAN_GPKG_PATH}"
        return
    fi

    local zip_path
    zip_path="${STATCAN_ZIP_PATH:-${WORKDIR}/csd-boundaries.zip}"

    if [[ ! -f "${zip_path}" ]]; then
        echo "→ Downloading StatCan CSD boundaries"
        curl -fsSL -o "${zip_path}" "${STATCAN_CSD_ZIP_URL}"
    fi

    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    unzip -o -q "${zip_path}" -d "${EXTRACT_DIR}"

    local gpkg_path
    gpkg_path="$(find "${EXTRACT_DIR}" -type f -name '*.gpkg' | head -n 1)"
    if [[ -z "${gpkg_path}" ]]; then
        echo "Unable to locate a .gpkg file in ${zip_path}" >&2
        exit 1
    fi

    printf '%s\n' "${gpkg_path}"
}

GPKG_PATH="$(resolve_gpkg_path)"
if [[ ! -f "${GPKG_PATH}" ]]; then
    echo "StatCan GeoPackage not found: ${GPKG_PATH}" >&2
    exit 1
fi

LAYER_NAME="${STATCAN_GPKG_LAYER:-$(
    ogrinfo -ro "${GPKG_PATH}" \
        | awk -F': ' '/^[[:space:]]*[0-9]+: / { print $2; exit }'
)}"

if [[ -z "${LAYER_NAME}" ]]; then
    echo "Unable to determine the StatCan layer name for ${GPKG_PATH}" >&2
    exit 1
fi

echo "→ Loading ${ROAD_SENSE_REGION_NAME} municipalities from ${GPKG_PATH}"

psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS ref; DROP TABLE IF EXISTS ${RAW_TABLE};"

ogr2ogr \
    -f PostgreSQL \
    PG:"${DATABASE_URL}" \
    "${GPKG_PATH}" \
    -dialect SQLITE \
    -sql "SELECT CSDNAME AS csd_name, PRUID AS pruid, PRNAME AS province_name, geom FROM ${LAYER_NAME} WHERE PRUID = '${ROAD_SENSE_REGION_PRUID}'" \
    -nln "${RAW_TABLE}" \
    -overwrite \
    -nlt PROMOTE_TO_MULTI \
    -t_srs EPSG:4326

psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS ref.municipalities;
CREATE TABLE ref.municipalities AS
SELECT
    csd_name,
    MIN(pruid)::TEXT AS pruid,
    MIN(province_name)::TEXT AS province_name,
    ST_Multi(ST_UnaryUnion(ST_Collect(geom)))::geometry(MULTIPOLYGON, 4326) AS geom
FROM ${RAW_TABLE}
GROUP BY csd_name;

ALTER TABLE ref.municipalities ADD PRIMARY KEY (csd_name);
CREATE INDEX idx_ref_municipalities_geom
    ON ref.municipalities
    USING GIST (geom);

DROP TABLE ${RAW_TABLE};
SQL

echo "→ ${ROAD_SENSE_REGION_NAME} municipalities loaded"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -c "SELECT count(*) AS municipality_count FROM ref.municipalities;"
