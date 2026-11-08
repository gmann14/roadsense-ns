#!/usr/bin/env bash
#
# Behaviour tests for scripts/migrate-railway.sh against a fake psql
# (scripts/tests/fakes/psql): ledger skip, stop-on-first-failure, production
# refusal, dry run, baseline, and no credentials on argv.

set -euo pipefail

# shellcheck source=scripts/tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCRIPT="$REPO_ROOT/scripts/migrate-railway.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MIGRATIONS="$WORK/migrations"
mkdir -p "$MIGRATIONS"
printf 'CREATE TABLE one();\n' > "$MIGRATIONS/20260101000001_one.sql"
printf 'CREATE TABLE two();\n' > "$MIGRATIONS/20260101000002_two.sql"
printf 'CREATE TABLE three();\n' > "$MIGRATIONS/20260101000003_three.sql"

LOCAL_URL="postgres://postgres:s3cret-pw@127.0.0.1:54322/postgres"
REMOTE_URL="postgresql://postgres:s3cret-pw@roundhouse.proxy.rlwy.net:41234/railway"

new_state() {
    STATE="$WORK/state-$1"
    rm -rf "$STATE"
    mkdir -p "$STATE"
    touch "$STATE/ledger" "$STATE/executed"
}

# run_migrate URL [args...]; sets OUTPUT and STATUS.
run_migrate() {
    local url="$1"
    shift
    set +e
    OUTPUT="$(
        PATH="$TESTS_DIR/fakes:$PATH" \
        FAKE_PSQL_STATE="$STATE" \
        ROADSENSE_MIGRATIONS_DIR="$MIGRATIONS" \
        DATABASE_URL="$url" \
        "$SCRIPT" "$@" 2>&1
    )"
    STATUS=$?
    set -e
}

executed() { tr '\n' ' ' < "$STATE/executed" | sed 's/ $//'; }
ledger() { sort "$STATE/ledger" | tr '\n' ' ' | sed 's/ $//'; }

begin_test "fresh database applies everything once"
new_state fresh
run_migrate "$LOCAL_URL"
assert_eq 0 "$STATUS" "exit status"
assert_eq "20260101000001_one.sql 20260101000002_two.sql 20260101000003_three.sql" "$(executed)" "all files executed in order"
assert_eq "20260101000001 20260101000002 20260101000003" "$(ledger)" "all versions recorded"

begin_test "re-run skips applied migrations"
run_migrate "$LOCAL_URL"
assert_eq 0 "$STATUS" "exit status"
assert_contains "$OUTPUT" "Nothing to apply" "reports up to date"
assert_eq "20260101000001_one.sql 20260101000002_two.sql 20260101000003_three.sql" "$(executed)" "no file executed twice"

begin_test "partial ledger applies only pending files"
new_state partial
touch "$STATE/ledger_table" "$STATE/schema"
printf '20260101000001\n' > "$STATE/ledger"
run_migrate "$LOCAL_URL"
assert_eq 0 "$STATUS" "exit status"
assert_eq "20260101000002_two.sql 20260101000003_three.sql" "$(executed)" "only pending files executed"
assert_eq "20260101000001 20260101000002 20260101000003" "$(ledger)" "ledger complete"

begin_test "first failure stops the run"
new_state failure
set +e
OUTPUT="$(
    PATH="$TESTS_DIR/fakes:$PATH" FAKE_PSQL_STATE="$STATE" FAKE_PSQL_FAIL_FILE="20260101000002_two.sql" \
    ROADSENSE_MIGRATIONS_DIR="$MIGRATIONS" DATABASE_URL="$LOCAL_URL" "$SCRIPT" 2>&1
)"
STATUS=$?
set -e
assert_eq 1 "$STATUS" "non-zero exit"
assert_contains "$OUTPUT" "FAILED: 20260101000002_two.sql" "names the failed file"
assert_contains "$OUTPUT" "simulated failure" "shows the psql error"
assert_eq "20260101000001_one.sql" "$(executed)" "later files not attempted"
assert_eq "20260101000001" "$(ledger)" "failed file not recorded"

begin_test "remote host refused without acknowledgement"
new_state remote
run_migrate "$REMOTE_URL"
assert_eq 1 "$STATUS" "non-zero exit"
assert_contains "$OUTPUT" "REFUSING" "explains refusal"
assert_eq "" "$(executed)" "nothing executed"
assert_eq "" "$(cat "$STATE/argv" 2>/dev/null || true)" "psql never invoked"

begin_test "remote dry run is allowed and read-only"
new_state remote-dry
touch "$STATE/ledger_table" "$STATE/schema"
printf '20260101000001\n' > "$STATE/ledger"
run_migrate "$REMOTE_URL" --dry-run
assert_eq 0 "$STATUS" "exit status"
assert_contains "$OUTPUT" "20260101000002_two.sql" "lists pending file"
assert_not_contains "$OUTPUT" "  - 20260101000001_one.sql" "omits applied file"
assert_eq "" "$(executed)" "nothing executed"
assert_not_contains "$(cat "$STATE/argv")" " -f " "no file passed to psql"

begin_test "remote apply with acknowledgement"
run_migrate "$REMOTE_URL" --i-know-this-is-production
assert_eq 0 "$STATUS" "exit status"
assert_eq "20260101000002_two.sql 20260101000003_three.sql" "$(executed)" "pending files executed"

begin_test "existing schema with empty ledger requires a baseline"
new_state baseline
touch "$STATE/schema"
run_migrate "$LOCAL_URL"
assert_eq 1 "$STATUS" "apply refused"
assert_contains "$OUTPUT" "--baseline-through" "suggests baseline"
assert_eq "" "$(executed)" "nothing executed"
run_migrate "$LOCAL_URL" --baseline-through 20260101000002
assert_eq 0 "$STATUS" "baseline exit status"
assert_eq "20260101000001 20260101000002" "$(ledger)" "baseline recorded through the version"
assert_eq "" "$(executed)" "baseline executes nothing"
run_migrate "$LOCAL_URL"
assert_eq 0 "$STATUS" "apply after baseline"
assert_eq "20260101000003_three.sql" "$(executed)" "only the post-baseline file runs"

begin_test "baseline rejects unknown versions"
run_migrate "$LOCAL_URL" --baseline-through 20991231000000
assert_eq 2 "$STATUS" "usage error"

begin_test "credentials never reach argv"
assert_not_contains "$(cat "$WORK"/state-*/argv)" "s3cret-pw" "password absent from argv"
assert_not_contains "$(cat "$WORK"/state-*/argv)" "postgres://" "URL absent from argv"
assert_contains "$(cat "$STATE/env")" "PGPASSWORD=s3cret-pw" "password passed via PGPASSWORD"
assert_not_contains "$(cat "$STATE/env")" "DATABASE_URL=postgres" "DATABASE_URL not inherited by psql"

begin_test "bad migration file name is rejected"
new_state badname
printf 'SELECT 1;\n' > "$MIGRATIONS/notaversion.sql"
run_migrate "$LOCAL_URL" --dry-run
rm -f "$MIGRATIONS/notaversion.sql"
assert_eq 1 "$STATUS" "non-zero exit"
assert_contains "$OUTPUT" "14-digit version" "explains naming rule"

begin_test "unknown flag is a usage error"
run_migrate "$LOCAL_URL" --force
assert_eq 2 "$STATUS" "usage error"

finish_tests
