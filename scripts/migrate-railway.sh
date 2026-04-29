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

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to parse DATABASE_URL without exposing it in psql argv." >&2
    exit 1
fi

RAW_DATABASE_URL="$DATABASE_URL"
unset DATABASE_URL

eval "$(
    DATABASE_URL="$RAW_DATABASE_URL" python3 - <<'PY'
import os
import shlex
import sys
from urllib.parse import parse_qs, unquote, urlsplit, urlunsplit

raw = os.environ["DATABASE_URL"]
try:
    parsed = urlsplit(raw)
    port = parsed.port
except ValueError as exc:
    print(f"echo {shlex.quote(f'DATABASE_URL is invalid: {exc}')} >&2", file=sys.stdout)
    print("exit 1", file=sys.stdout)
    raise SystemExit

if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
    print("echo 'DATABASE_URL must be a postgres:// or postgresql:// URI.' >&2")
    print("exit 1")
    raise SystemExit

database = unquote(parsed.path[1:] if parsed.path.startswith("/") else parsed.path) or "postgres"
query = parse_qs(parsed.query)
env = {
    "PGHOST": parsed.hostname,
    "PGPORT": str(port or 5432),
    "PGUSER": unquote(parsed.username or ""),
    "PGPASSWORD": unquote(parsed.password or ""),
    "PGDATABASE": database,
    "PGCONNECT_TIMEOUT": os.environ.get("PGCONNECT_TIMEOUT", "10"),
    "PGAPPNAME": os.environ.get("PGAPPNAME", "roadsense-migrate-railway"),
}
if query.get("sslmode"):
    env["PGSSLMODE"] = query["sslmode"][-1]
elif os.environ.get("PGSSLMODE"):
    env["PGSSLMODE"] = os.environ["PGSSLMODE"]

for key, value in env.items():
    print(f"export {key}={shlex.quote(value)}")

netloc = parsed.hostname
if port:
    netloc = f"{netloc}:{port}"
redacted = urlunsplit((parsed.scheme, netloc, parsed.path, "", ""))
print(f"export DATABASE_URL_REDACTED={shlex.quote(redacted)}")
PY
)"

psql_db() {
    psql "$@"
}

echo "→ Target: $DATABASE_URL_REDACTED"
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
psql_db -v ON_ERROR_STOP=1 <<'SQL'
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
# stats MV refresh, etc.) won't fire through Postgres. The Deno service runs
# the equivalent in-process scheduler when deployed on Railway.
echo ""
echo "→ Checking pg_cron availability"
HAS_PG_CRON="$(psql_db -tAc "SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pg_cron');")"
if [[ "$HAS_PG_CRON" == "t" ]]; then
    echo "  pg_cron available — using real extension"
    psql_db -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
else
    echo "  pg_cron NOT available — installing no-op stubs"
    echo "  (scheduled jobs will not fire; see docs/implementation/13-railway-deno-migration.md)"
    psql_db -v ON_ERROR_STOP=1 <<'SQL'
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

-- Older versions of this script unscheduled only one jobid, while several
-- migrations resolve a single jobid by jobname before calling unschedule().
-- Clean up those historical duplicates before adding the unique guard.
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
    -- Real DELETE so re-running migrate-railway.sh doesn't pile up duplicate
    -- rows in cron.job (the schedule/unschedule pattern is the standard "find
    -- by jobname, then re-schedule" idiom in our migrations).
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
# (which seeds a storage bucket and references storage.objects) applies cleanly.
# We're not deploying photo upload yet (deferred to R2), so these stubs just
# prevent the migration from erroring — no real storage behavior.
echo ""
echo "→ Installing storage.* stubs (photo upload deferred until R2 is set up)"
psql_db -v ON_ERROR_STOP=1 <<'SQL'
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

# 4. Apply each migration in chronological filename order.
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

    if psql_db -v ON_ERROR_STOP=1 -f "$migration" >/dev/null 2>&1; then
        echo "       OK"
    else
        # Re-run with output so we can see the error
        echo "       FAILED — replaying with full output:"
        psql_db -v ON_ERROR_STOP=1 -f "$migration" 2>&1 | head -20 | sed 's/^/         /'
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
