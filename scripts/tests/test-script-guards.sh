#!/usr/bin/env bash
#
# Guard-rail tests that need no network or database: host classification in
# scripts/lib/pg-env.sh, and seeded-e2e-smoke.sh refusing production targets.

set -euo pipefail

# shellcheck source=scripts/tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=scripts/lib/pg-env.sh
source "$REPO_ROOT/scripts/lib/pg-env.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

yes_no() { if "$@"; then echo yes; else echo no; fi; }

begin_test "local host classification"
assert_eq yes "$(yes_no roadsense_is_local_host localhost)" "localhost"
assert_eq yes "$(yes_no roadsense_is_local_host 127.0.0.1)" "127.0.0.1"
assert_eq yes "$(yes_no roadsense_is_local_host ::1)" "::1"
assert_eq yes "$(yes_no roadsense_is_local_host host.docker.internal)" "host.docker.internal"
assert_eq no "$(yes_no roadsense_is_local_host roundhouse.proxy.rlwy.net)" "Railway proxy host"
assert_eq no "$(yes_no roadsense_is_local_host postgis.railway.internal)" "Railway private host"
assert_eq no "$(yes_no roadsense_is_local_host 127.0.0.1.evil.example)" "lookalike host"

begin_test "production API classification"
assert_eq yes "$(yes_no roadsense_is_production_api_url https://api.nsroadsense.ca/functions/v1)" "custom domain"
assert_eq yes "$(yes_no roadsense_is_production_api_url https://API.nsroadsense.ca:443/functions/v1)" "case and port"
assert_eq yes "$(yes_no roadsense_is_production_api_url https://api-production-075e9.up.railway.app/functions/v1)" "Railway origin"
assert_eq no "$(yes_no roadsense_is_production_api_url http://127.0.0.1:54321/functions/v1)" "local stack"
assert_eq no "$(yes_no roadsense_is_production_api_url https://api.nsroadsense.ca.evil.example/x)" "lookalike host"

begin_test "URL parsing exports PG* without credentials in the redacted URL"
(
    roadsense_pg_env_from_url "postgresql://user%40x:p%3Ass@db.example:6543/rs?sslmode=require"
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$PGHOST" "$PGPORT" "$PGUSER" "$PGPASSWORD" "$PGDATABASE" "$PGSSLMODE" "$ROADSENSE_DB_URL_REDACTED"
) > "$WORK/parsed"
assert_eq "db.example|6543|user@x|p:ss|rs|require|postgresql://db.example:6543/rs" "$(cat "$WORK/parsed")" "parsed fields"

begin_test "invalid URL is rejected"
if (roadsense_pg_env_from_url "mysql://x@y/z") 2>/dev/null; then
    fail "mysql URL accepted"
else
    pass "non-postgres scheme rejected"
fi

run_seeded() {
    set +e
    OUTPUT="$(
        PATH="$TESTS_DIR/fakes:$PATH" FAKE_PSQL_STATE="$WORK/psql" \
        SUPABASE_ANON_KEY=test-key "$@" "$REPO_ROOT/scripts/seeded-e2e-smoke.sh" 2>&1
    )"
    STATUS=$?
    set -e
}

begin_test "seeded smoke refuses the production API"
run_seeded env FUNCTIONS_BASE_URL=https://api.nsroadsense.ca/functions/v1 DATABASE_URL=postgres://u:p@127.0.0.1:5432/postgres
assert_eq 1 "$STATUS" "non-zero exit"
assert_contains "$OUTPUT" "Refusing to run seeded-e2e-smoke.sh against production" "explains refusal"

begin_test "seeded smoke refuses a remote database without the flag"
run_seeded env FUNCTIONS_BASE_URL=http://127.0.0.1:54321/functions/v1 DATABASE_URL=postgres://u:p@roundhouse.proxy.rlwy.net:5432/railway
assert_eq 1 "$STATUS" "non-zero exit"
assert_contains "$OUTPUT" "non-local database host" "explains refusal"
assert_eq "" "$(cat "$WORK/psql/argv" 2>/dev/null || true)" "psql never invoked"

begin_test "migrate-railway refuses a remote URL before connecting"
set +e
OUTPUT="$(PATH="$TESTS_DIR/fakes:$PATH" FAKE_PSQL_STATE="$WORK/psql2" DATABASE_URL=postgres://u:p@roundhouse.proxy.rlwy.net:5432/railway "$REPO_ROOT/scripts/migrate-railway.sh" 2>&1)"
STATUS=$?
set -e
assert_eq 1 "$STATUS" "non-zero exit"
assert_eq "" "$(cat "$WORK/psql2/argv" 2>/dev/null || true)" "psql never invoked"

begin_test "osm-import.sh leaves no import scratch data on the volume"
import_script="$REPO_ROOT/scripts/osm-import.sh"
assert_eq yes "$(yes_no grep -Eq '^[[:space:]]+--drop[[:space:]]+\\$' "$import_script")" "osm2pgsql runs with --drop"
finalize_line="$(grep -n 'SELECT finalize_road_segment_refresh' "$import_script" | head -1 | cut -d: -f1)"
truncate_lines="$(grep -n 'TRUNCATE road_segments_staging' "$import_script" | cut -d: -f1 | tr '\n' ' ')"
last_truncate="$(echo "$truncate_lines" | awk '{print $NF}')"
assert_eq yes "$(yes_no test "${last_truncate:-0}" -gt "${finalize_line:-999999}")" "staging is emptied after the refresh"

finish_tests
