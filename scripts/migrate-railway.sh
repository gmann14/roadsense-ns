#!/usr/bin/env bash
#
# Apply pending supabase/migrations/*.sql files to a plain Postgres/PostGIS
# database (the Railway deploy), exactly once each.
#
# Ledger: supabase_migrations.schema_migrations(version, name), the same
# table `supabase db push` reads and writes. A file whose version (the
# 14-digit filename prefix) is already in the ledger is skipped, so this
# script and `supabase db push --db-url ...` agree on what has been applied.
#
# Each pending file runs in its own transaction
# (`psql -v ON_ERROR_STOP=1 --single-transaction`) together with its ledger
# insert, so a file is either fully applied and recorded, or not at all. The
# first failure stops the run with a non-zero exit; later files are not
# attempted.
#
# Usage:
#   DATABASE_URL=postgres://... scripts/migrate-railway.sh --dry-run
#   DATABASE_URL=postgres://... scripts/migrate-railway.sh
#   DATABASE_URL=postgres://... scripts/migrate-railway.sh --baseline-through 20260612182000
#
# Options:
#   --dry-run                     Read-only: print the ledger state and the
#                                 pending files, then exit. Allowed against
#                                 any host.
#   --baseline-through VERSION    Record every local migration with
#                                 version <= VERSION as applied WITHOUT running
#                                 it. For a database that was migrated by the
#                                 old ledger-less version of this script.
#   --i-know-this-is-production   Required for any write (apply or baseline)
#                                 to a non-local host. Railway only has a
#                                 production environment, so every remote
#                                 host is treated as production.
#
# Production deploys use `supabase db push` (see
# docs/implementation/05-deployment-and-observability.md). Use this script to
# bootstrap a fresh Railway database (it also installs the role, pg_cron and
# storage stand-ins that plain Postgres lacks) or to baseline the ledger.
#
# DATABASE_URL is parsed into libpq PG* environment variables; the URL and
# password never appear in psql's argv.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="${ROADSENSE_MIGRATIONS_DIR:-$ROOT_DIR/supabase/migrations}"
LEDGER_TABLE="supabase_migrations.schema_migrations"

# shellcheck source=scripts/lib/pg-env.sh
source "$ROOT_DIR/scripts/lib/pg-env.sh"

usage() {
    sed -n '/^# Usage:/,/^# Production deploys/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
BASELINE_THROUGH=""
PRODUCTION_ACK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --baseline-through)
            if [[ $# -lt 2 ]]; then
                echo "--baseline-through needs a VERSION argument" >&2
                exit 2
            fi
            BASELINE_THROUGH="$2"
            shift
            ;;
        --i-know-this-is-production)
            PRODUCTION_ACK=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -n "$BASELINE_THROUGH" && "$DRY_RUN" -eq 1 ]]; then
    echo "--dry-run and --baseline-through are mutually exclusive" >&2
    exit 2
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found; install libpq (brew install libpq)" >&2
    exit 1
fi

roadsense_pg_env_from_database_url
export PGAPPNAME="${PGAPPNAME:-roadsense-migrate-railway}"
# Hide "already exists, skipping" NOTICE noise; warnings and errors still print.
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"

# --- Collect local migrations -------------------------------------------------

# Plain indexed arrays and newline lists only: macOS ships bash 3.2, which has
# no associative arrays.
FILES=()
VERSIONS=()
LOCAL_VERSIONS=""

# list_has LIST ITEM: exact whole-line match in a newline-separated list.
list_has() {
    printf '%s\n' "$1" | grep -Fxq -- "$2"
}

previous_version=""
previous_name=""
while IFS= read -r migration; do
    name="$(basename "$migration")"
    version="${name%%_*}"
    if [[ ! "$version" =~ ^[0-9]{14}$ ]]; then
        echo "Migration file name must start with a 14-digit version: $name" >&2
        exit 1
    fi
    if [[ "$version" == "$previous_version" ]]; then
        echo "Duplicate migration version $version: $previous_name and $name" >&2
        exit 1
    fi
    previous_version="$version"
    previous_name="$name"
    FILES+=("$migration")
    VERSIONS+=("$version")
    LOCAL_VERSIONS="${LOCAL_VERSIONS}${version}"$'\n'
done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' | sort)

if [[ "${#FILES[@]}" -eq 0 ]]; then
    echo "No migrations found in $MIGRATIONS_DIR" >&2
    exit 1
fi

# --- Target safety -----------------------------------------------------------

TARGET_IS_LOCAL=0
if roadsense_is_local_host "$PGHOST"; then
    TARGET_IS_LOCAL=1
fi

echo "→ Target: $ROADSENSE_DB_URL_REDACTED"
echo "→ Migrations dir: $MIGRATIONS_DIR (${#FILES[@]} files)"

if [[ "$TARGET_IS_LOCAL" -eq 0 && "$DRY_RUN" -eq 0 && "$PRODUCTION_ACK" -eq 0 ]]; then
    cat >&2 <<EOF

REFUSING to write to non-local host '$PGHOST'.
RoadSense has no remote staging database, so every remote host is treated as
production. Production migrations go through 'supabase db push' (see
docs/implementation/05-deployment-and-observability.md). Run with --dry-run to
inspect the ledger, or pass --i-know-this-is-production if you really mean it.
EOF
    exit 1
fi

# --- Ledger state ------------------------------------------------------------

psql_query() {
    psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"
}

ledger_exists="$(psql_query "SELECT to_regclass('${LEDGER_TABLE}') IS NOT NULL;")"
schema_exists="$(psql_query "SELECT to_regclass('public.road_segments') IS NOT NULL;")"

APPLIED_VERSIONS=""
applied_count=0
if [[ "$ledger_exists" == "t" ]]; then
    APPLIED_VERSIONS="$(psql_query "SELECT version FROM ${LEDGER_TABLE} ORDER BY version;")"
    while IFS= read -r applied_version; do
        [[ -z "$applied_version" ]] && continue
        applied_count=$((applied_count + 1))
        if ! list_has "$LOCAL_VERSIONS" "$applied_version"; then
            echo "  warning: ledger has version $applied_version with no local file (applied from another branch?)" >&2
        fi
    done <<< "$APPLIED_VERSIONS"
elif [[ "$ledger_exists" != "f" ]]; then
    echo "Unexpected ledger probe result: '$ledger_exists'" >&2
    exit 1
fi

PENDING_FILES=()
PENDING_VERSIONS=()
for i in "${!FILES[@]}"; do
    if ! list_has "$APPLIED_VERSIONS" "${VERSIONS[$i]}"; then
        PENDING_FILES+=("${FILES[$i]}")
        PENDING_VERSIONS+=("${VERSIONS[$i]}")
    fi
done

ledger_is_empty=0
if [[ "$applied_count" -eq 0 ]]; then
    ledger_is_empty=1
fi

echo "→ Ledger: ${LEDGER_TABLE} $([[ "$ledger_exists" == "t" ]] && echo "present, $applied_count applied" || echo "absent")"
echo "→ Pending: ${#PENDING_FILES[@]}"

needs_baseline_message() {
    cat >&2 <<EOF

This database already has the RoadSense schema (public.road_segments exists)
but the migration ledger is empty, so every migration looks pending.
Applying them would replay the whole history over live data.

Baseline the ledger first with the newest migration that is already applied:
  scripts/migrate-railway.sh --baseline-through <VERSION> [--i-know-this-is-production]
docs/implementation/05-deployment-and-observability.md has a query to find it.
EOF
}

# --- Dry run -----------------------------------------------------------------

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    if [[ "${#PENDING_FILES[@]}" -eq 0 ]]; then
        echo "DRY RUN: database is up to date."
    else
        echo "DRY RUN: would apply, in order:"
        for migration in "${PENDING_FILES[@]}"; do
            echo "  - $(basename "$migration")"
        done
    fi
    if [[ "$ledger_is_empty" -eq 1 && "$schema_exists" == "t" ]]; then
        needs_baseline_message
    fi
    exit 0
fi

ensure_ledger() {
    psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
    version TEXT NOT NULL PRIMARY KEY
);
ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS statements TEXT[];
ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS name TEXT;
SQL
}

# --- Baseline ----------------------------------------------------------------

if [[ -n "$BASELINE_THROUGH" ]]; then
    if [[ ! "$BASELINE_THROUGH" =~ ^[0-9]{14}$ ]]; then
        echo "--baseline-through must be a 14-digit migration version, got '$BASELINE_THROUGH'" >&2
        exit 2
    fi
    if ! list_has "$LOCAL_VERSIONS" "$BASELINE_THROUGH"; then
        echo "No local migration has version $BASELINE_THROUGH" >&2
        exit 2
    fi

    BASELINE_ROWS=()
    for i in ${PENDING_VERSIONS[@]+"${!PENDING_VERSIONS[@]}"}; do
        version="${PENDING_VERSIONS[$i]}"
        if [[ "$version" < "$BASELINE_THROUGH" || "$version" == "$BASELINE_THROUGH" ]]; then
            name="$(basename "${PENDING_FILES[$i]}" .sql)"
            BASELINE_ROWS+=("${version}:${name#*_}")
        fi
    done

    if [[ "${#BASELINE_ROWS[@]}" -eq 0 ]]; then
        echo "Nothing to baseline: every migration through $BASELINE_THROUGH is already recorded."
        exit 0
    fi

    ensure_ledger
    rows_csv="$(IFS=,; echo "${BASELINE_ROWS[*]}")"
    echo "→ Recording ${#BASELINE_ROWS[@]} migration(s) through $BASELINE_THROUGH as applied (not executing them)"
    psql -X -q -v ON_ERROR_STOP=1 --single-transaction -v rows="$rows_csv" -f - <<'SQL'
INSERT INTO supabase_migrations.schema_migrations (version, name)
SELECT split_part(row_spec, ':', 1), split_part(row_spec, ':', 2)
FROM unnest(string_to_array(:'rows', ',')) AS row_spec
ON CONFLICT (version) DO NOTHING;
SQL
    echo "→ Baseline recorded. Run --dry-run to see what is still pending."
    exit 0
fi

# --- Apply -------------------------------------------------------------------

if [[ "$ledger_is_empty" -eq 1 && "$schema_exists" == "t" ]]; then
    needs_baseline_message
    exit 1
fi

if [[ "${#PENDING_FILES[@]}" -eq 0 ]]; then
    echo "→ Nothing to apply; database is up to date."
    exit 0
fi

# 1. Pre-flight: Supabase-only roles as no-op stand-ins so GRANTs apply.
echo ""
echo "→ Ensuring Supabase-style roles exist (anon, authenticated, service_role)"
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
    CREATE ROLE anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
    CREATE ROLE authenticated NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
    CREATE ROLE service_role NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
SQL

# 2. Pre-flight: stub pg_cron when the real extension is unavailable.
#
# Railway's PostGIS template doesn't ship pg_cron. A stub `cron` schema with
# no-op scheduling functions lets the existing migrations apply; the Deno
# service's in-process scheduler (supabase/functions/_shared/scheduler.ts)
# runs the jobs instead.
echo "→ Checking pg_cron availability"
HAS_PG_CRON="$(psql_query "SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron');")"
if [[ "$HAS_PG_CRON" == "t" ]]; then
    echo "  pg_cron available; using the real extension"
    psql -X -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
else
    echo "  pg_cron not available; installing no-op stubs"
    psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS cron;

-- Stub the catalog table pg_cron creates so DELETE/SELECT against cron.job
-- don't error in migrations that use the "find by jobname, then unschedule"
-- pattern.
CREATE TABLE IF NOT EXISTS cron.job (
    jobid BIGSERIAL PRIMARY KEY,
    schedule TEXT,
    command TEXT,
    nodename TEXT,
    nodeport INTEGER,
    database TEXT,
    username TEXT,
    active BOOLEAN DEFAULT FALSE,
    jobname TEXT
);

-- Older versions of this script unscheduled only one jobid; clean up those
-- historical duplicates before adding the unique guard.
DELETE FROM cron.job old_job
USING cron.job newer_job
WHERE old_job.jobname IS NOT NULL
  AND old_job.jobname = newer_job.jobname
  AND old_job.jobid < newer_job.jobid;

CREATE UNIQUE INDEX IF NOT EXISTS cron_job_jobname_unique
    ON cron.job (jobname)
    WHERE jobname IS NOT NULL;

CREATE OR REPLACE FUNCTION cron.schedule(
    job_name TEXT,
    schedule TEXT,
    command TEXT
) RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    new_id BIGINT;
BEGIN
    INSERT INTO cron.job (schedule, command, jobname)
    VALUES (schedule, command, job_name)
    ON CONFLICT (jobname) WHERE jobname IS NOT NULL DO UPDATE
        SET schedule = EXCLUDED.schedule,
            command = EXCLUDED.command,
            active = FALSE
    RETURNING jobid INTO new_id;
    RAISE NOTICE 'cron.schedule stub: job=% schedule=% (no-op on Railway)', job_name, schedule;
    RETURN new_id;
END
$fn$;

CREATE OR REPLACE FUNCTION cron.unschedule(job_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $fn$
BEGIN
    DELETE FROM cron.job WHERE jobname = job_name;
    RETURN FOUND;
END
$fn$;

CREATE OR REPLACE FUNCTION cron.unschedule(job_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $fn$
DECLARE
    target_jobname TEXT;
BEGIN
    SELECT jobname INTO target_jobname FROM cron.job WHERE jobid = job_id;

    IF target_jobname IS NOT NULL THEN
        DELETE FROM cron.job WHERE jobname = target_jobname;
    ELSE
        DELETE FROM cron.job WHERE jobid = job_id;
    END IF;

    RETURN FOUND;
END
$fn$;
SQL
fi

# 3. Pre-flight: stub Supabase Storage tables so the pothole-photos migration
# (which seeds a bucket and references storage.objects) applies. Photo upload
# is deferred until R2; these stubs carry no storage behaviour.
echo "→ Installing storage.* stubs (photo upload deferred until R2)"
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    owner UUID,
    public BOOLEAN DEFAULT FALSE,
    file_size_limit BIGINT,
    allowed_mime_types TEXT[],
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    bucket_id TEXT REFERENCES storage.buckets(id),
    name TEXT,
    owner UUID,
    metadata JSONB,
    path_tokens TEXT[],
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    last_accessed_at TIMESTAMPTZ DEFAULT now()
);
SQL

echo "→ Ensuring migration ledger ${LEDGER_TABLE} exists"
ensure_ledger

# 4. Apply each pending migration in its own transaction, recording it in the
# ledger inside that same transaction. The ledger insert runs first so a
# concurrent runner that already recorded this version fails fast on the
# primary key instead of re-running the file.
echo ""
echo "→ Applying ${#PENDING_FILES[@]} migration(s)"

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

applied_now=0
total_pending="${#PENDING_FILES[@]}"
for i in "${!PENDING_FILES[@]}"; do
    migration="${PENDING_FILES[$i]}"
    version="${PENDING_VERSIONS[$i]}"
    file_name="$(basename "$migration")"
    ledger_name="$(basename "$migration" .sql)"
    ledger_name="${ledger_name#*_}"
    echo "  [$((i + 1))/$total_pending] $file_name"

    if ! psql -X -q -v ON_ERROR_STOP=1 --single-transaction \
        -v version="$version" -v name="$ledger_name" \
        -f - -f "$migration" >"$log_file" 2>&1 <<'SQL'
INSERT INTO supabase_migrations.schema_migrations (version, name)
VALUES (:'version', :'name');
SQL
    then
        echo "" >&2
        echo "FAILED: $file_name (transaction rolled back; not recorded in the ledger)" >&2
        tail -n 40 "$log_file" | sed 's/^/    /' >&2
        echo "" >&2
        echo "Stopped. $applied_now applied in this run; $((total_pending - applied_now)) not applied, starting with $file_name." >&2
        exit 1
    fi
    applied_now=$((applied_now + 1))
done

echo ""
echo "→ Done: $applied_now migration(s) applied and recorded."
