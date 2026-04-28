#!/usr/bin/env bash
#
# Apply every supabase/migrations/*.sql file (sorted by filename) against an
# arbitrary Postgres URL — designed for the Railway PostGIS deploy where we
# can't use the Supabase CLI's `db push` (it requires a Supabase project).
#
# Idempotency: every existing migration uses CREATE TABLE/INDEX/TYPE IF NOT
# EXISTS, DO $$ EXCEPTION WHEN duplicate_object THEN NULL $$, or CREATE OR
# REPLACE. Re-running this script against a partially-applied database is safe.
#
# Usage:
#   DATABASE_URL=postgres://... ./scripts/migrate-railway.sh
#   DATABASE_URL=postgres://... ./scripts/migrate-railway.sh --dry-run
#
# Pre-flight: also creates the Supabase-only roles (anon, authenticated,
# service_role) as stand-ins so the existing GRANT statements don't error
# against a plain Postgres instance.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="$ROOT_DIR/supabase/migrations"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

: "${DATABASE_URL:?DATABASE_URL must be set}"

if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found; install libpq (brew install libpq)" >&2
    exit 1
fi

echo "→ Target: ${DATABASE_URL%%@*}@***"
echo "→ Migrations dir: $MIGRATIONS_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "DRY RUN — would apply (in this order):"
    find "$MIGRATIONS_DIR" -name '*.sql' -type f | sort | while read -r f; do
        echo "  - $(basename "$f")"
    done
    exit 0
fi

# 1. Pre-flight: create the Supabase-only roles as no-op stand-ins.
echo ""
echo "→ Ensuring Supabase-style roles exist (anon, authenticated, service_role)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
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
# Railway's PostGIS template doesn't ship pg_cron and there's no easy way to
# add it (would need shared_preload_libraries config, which Railway doesn't
# expose on the standard template). Create a stub `cron` schema with no-op
# scheduling functions so the existing migrations still apply cleanly.
#
# The implication: scheduled refreshes (nightly_recompute_aggregates, public
# stats MV refresh, etc.) won't fire automatically. We need to run them via
# a Railway scheduled service — tracked separately as a follow-up.
echo ""
echo "→ Checking pg_cron availability"
HAS_PG_CRON="$(psql "$DATABASE_URL" -tAc "SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pg_cron');")"
if [[ "$HAS_PG_CRON" == "t" ]]; then
    echo "  pg_cron available — using real extension"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
else
    echo "  pg_cron NOT available — installing no-op stubs"
    echo "  (scheduled jobs will not fire; see docs/implementation/13-railway-deno-migration.md)"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS cron;

-- Stub the catalog table pg_cron creates so DELETE/SELECT against cron.job
-- don't error in migrations that use the standard "find by jobname, then
-- unschedule" pattern.
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
    RAISE NOTICE 'cron.unschedule stub: job=% (no-op on Railway)', job_name;
    RETURN TRUE;
END
$fn$;

CREATE OR REPLACE FUNCTION cron.unschedule(job_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $fn$
BEGIN
    RAISE NOTICE 'cron.unschedule stub: job_id=% (no-op on Railway)', job_id;
    RETURN TRUE;
END
$fn$;
SQL
fi

# 3. Pre-flight: stub Supabase Storage tables so the pothole-photos migration
# (which seeds a storage bucket and references storage.objects) applies cleanly.
# We're not deploying photo upload yet (deferred to R2), so these stubs just
# prevent the migration from erroring — no real storage behavior.
echo ""
echo "→ Installing storage.* stubs (photo upload deferred until R2 is set up)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
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

# 2. Apply each migration in chronological filename order.
echo ""
echo "→ Applying migrations"

count=0
fail_count=0
fail_files=()

while read -r migration; do
    name="$(basename "$migration")"
    count=$((count + 1))
    echo ""
    echo "  [$count] $name"

    if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$migration" >/dev/null 2>&1; then
        echo "       OK"
    else
        # Re-run with output so we can see the error
        echo "       FAILED — replaying with full output:"
        psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$migration" 2>&1 | head -20 | sed 's/^/         /'
        fail_count=$((fail_count + 1))
        fail_files+=("$name")
    fi
done < <(find "$MIGRATIONS_DIR" -name '*.sql' -type f | sort)

echo ""
echo "→ Done: $count migrations attempted, $fail_count failed"
if [[ "$fail_count" -gt 0 ]]; then
    echo ""
    echo "Failed migrations:"
    printf '  - %s\n' "${fail_files[@]}"
    exit 1
fi
