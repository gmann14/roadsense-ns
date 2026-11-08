#!/usr/bin/env bash
#
# Read-only: list the readings_YYYY_MM partitions that the next
# drop_old_readings_partitions() run will DROP (irreversibly), with row counts.
# Mirrors the cutoff in 20260702140000_fix_drop_old_readings_partitions.sql:
# a partition goes once the month after its name is at or before
# date_trunc('month', now() - 6 months).
#
# Usage:
#   DATABASE_URL=postgres://... scripts/report-expiring-partitions.sh [--fail-if-rows]
#
# --fail-if-rows exits 3 when any expiring partition still holds rows, so a
# deploy can stop until someone has decided those rows may go (or exported
# them). Run it before the first deploy of the partition-drop fix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pg-env.sh
source "${SCRIPT_DIR}/lib/pg-env.sh"

FAIL_IF_ROWS=0
for arg in "$@"; do
    case "${arg}" in
        --fail-if-rows) FAIL_IF_ROWS=1 ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            exit 2
            ;;
    esac
done

if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found; install libpq (brew install libpq)" >&2
    exit 1
fi

# Credentials reach psql through PG* variables, never argv.
roadsense_pg_env_from_database_url
export PGAPPNAME="${PGAPPNAME:-roadsense-report-expiring-partitions}"

query() {
    psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"
}

cutoff="$(query "SELECT date_trunc('month', now() - INTERVAL '6 months')::DATE;")"
echo "→ Target: ${ROADSENSE_DB_URL_REDACTED}"
echo "→ Drop cutoff: partitions for months ending on or before ${cutoff}"

partitions="$(query "
SELECT c.relname
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'public.readings'::regclass
  AND c.relname ~ '^readings_[0-9]{4}_[0-9]{2}$'
  AND (make_date(substring(c.relname FROM 10 FOR 4)::INT, substring(c.relname FROM 15 FOR 2)::INT, 1)
       + INTERVAL '1 month')::DATE <= date_trunc('month', now() - INTERVAL '6 months')::DATE
ORDER BY c.relname;")"

total=0
if [[ -z "${partitions}" ]]; then
    echo "  none: the next drop removes nothing"
else
    while IFS= read -r partition; do
        # Names were filtered by the regex above; re-check before interpolating.
        if [[ ! "${partition}" =~ ^readings_[0-9]{4}_[0-9]{2}$ ]]; then
            echo "Unexpected partition name: ${partition}" >&2
            exit 1
        fi
        rows="$(query "SELECT count(*) FROM public.${partition};")"
        if [[ ! "${rows}" =~ ^[0-9]+$ ]]; then
            echo "Unexpected row count for ${partition}: ${rows}" >&2
            exit 1
        fi
        echo "  ${partition}: ${rows} rows WILL BE DROPPED"
        total=$((total + rows))
    done <<< "${partitions}"
fi

echo "→ Total rows in expiring partitions: ${total}"

if [[ "${FAIL_IF_ROWS}" -eq 1 && "${total}" -gt 0 ]]; then
    echo "Expiring partitions still hold ${total} rows; the drop is irreversible." >&2
    echo "Take/verify a database snapshot, then re-run the deploy acknowledging the drop." >&2
    exit 3
fi
