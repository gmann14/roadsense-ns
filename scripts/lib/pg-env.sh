# shellcheck shell=bash
#
# Shared helpers for scripts that talk to Postgres.
#
# Source this file; do not execute it. It provides:
#
#   roadsense_pg_env_from_url URL
#       Parses a postgres:// URL and exports libpq PG* variables (PGHOST,
#       PGPORT, PGUSER, PGPASSWORD, PGDATABASE, optional PGSSLMODE), plus
#       ROADSENSE_DB_HOST and ROADSENSE_DB_URL_REDACTED (no credentials).
#       Afterwards psql, pg_dump, osm2pgsql and ogr2ogr connect through the
#       environment, so the URL and password never appear in any process's
#       argv (visible to other users via `ps`).
#
#   roadsense_pg_env_from_database_url
#       Same, reading DATABASE_URL, then unsetting DATABASE_URL so it is not
#       inherited by child processes either.
#
#   roadsense_is_local_host HOST
#       True for loopback hosts and local Docker hostnames.
#
#   roadsense_is_production_api_url URL
#       True when URL points at a known production API host.
#
# Requires python3 (URL parsing and percent-decoding).

# Read with `read -d ''` rather than inside $(...): bash 3.2 mis-parses
# quotes in a heredoc nested in a command substitution.
ROADSENSE_PG_ENV_PY=""
IFS= read -r -d '' ROADSENSE_PG_ENV_PY <<'PY' || true
import os
import shlex
import sys
from urllib.parse import parse_qs, unquote, urlsplit, urlunsplit

raw = os.environ["ROADSENSE_RAW_DB_URL"]
try:
    parsed = urlsplit(raw)
    port = parsed.port
except ValueError as exc:
    print(f"database URL is invalid: {exc}", file=sys.stderr)
    sys.exit(1)

if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
    print("database URL must be a postgres:// or postgresql:// URI with a host.", file=sys.stderr)
    sys.exit(1)

database = unquote(parsed.path[1:] if parsed.path.startswith("/") else parsed.path) or "postgres"
query = parse_qs(parsed.query)
env = {
    "PGHOST": parsed.hostname,
    "PGPORT": str(port or 5432),
    "PGUSER": unquote(parsed.username or ""),
    "PGPASSWORD": unquote(parsed.password or ""),
    "PGDATABASE": database,
    "PGCONNECT_TIMEOUT": os.environ.get("PGCONNECT_TIMEOUT", "10"),
    "ROADSENSE_DB_HOST": parsed.hostname,
}
if query.get("sslmode"):
    env["PGSSLMODE"] = query["sslmode"][-1]
elif os.environ.get("PGSSLMODE"):
    env["PGSSLMODE"] = os.environ["PGSSLMODE"]

netloc = parsed.hostname
if ":" in netloc:
    netloc = f"[{netloc}]"
if port:
    netloc = f"{netloc}:{port}"
env["ROADSENSE_DB_URL_REDACTED"] = urlunsplit((parsed.scheme, netloc, parsed.path, "", ""))

for key, value in env.items():
    if value == "" and key in {"PGUSER", "PGPASSWORD"}:
        # Never inherit a stale credential from the calling shell.
        print(f"unset {key}")
    else:
        print(f"export {key}={shlex.quote(value)}")
PY

roadsense_pg_env_from_url() {
    local raw_url="${1:-}"
    if [[ -z "${raw_url}" ]]; then
        echo "roadsense_pg_env_from_url: database URL is empty" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 is required to parse the database URL without exposing it in argv." >&2
        return 1
    fi

    local exports
    # The URL is passed through the environment, never argv.
    if ! exports="$(ROADSENSE_RAW_DB_URL="${raw_url}" python3 -c "${ROADSENSE_PG_ENV_PY}")"; then
        return 1
    fi
    eval "${exports}"
}

roadsense_pg_env_from_database_url() {
    if [[ -z "${DATABASE_URL:-}" ]]; then
        echo "DATABASE_URL must be set" >&2
        return 1
    fi
    local url="${DATABASE_URL}"
    unset DATABASE_URL
    roadsense_pg_env_from_url "${url}"
}

roadsense_is_local_host() {
    local host
    host="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "${host}" in
        localhost|*.localhost|::1|\[::1\]|host.docker.internal|supabase_db_*)
            return 0
            ;;
        127.*)
            [[ "${host}" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
            return
            ;;
    esac
    return 1
}

# Hosts that serve the production API. Keep in sync with
# cloudflare/api-proxy/wrangler.toml and docs/implementation/05.
ROADSENSE_PRODUCTION_API_HOSTS=(
    "api.nsroadsense.ca"
    "tiles.nsroadsense.ca"
    "nsroadsense.ca"
    "www.nsroadsense.ca"
    "api-production-075e9.up.railway.app"
)

roadsense_url_host() {
    local url="${1:-}"
    local rest="${url#*://}"
    rest="${rest#*@}"
    rest="${rest%%/*}"
    rest="${rest%%\?*}"
    if [[ "${rest}" == \[* ]]; then
        rest="${rest%%]*}]"
    else
        rest="${rest%%:*}"
    fi
    printf '%s' "${rest}" | tr '[:upper:]' '[:lower:]'
}

roadsense_is_production_api_url() {
    local host
    host="$(roadsense_url_host "${1:-}")"
    local known
    for known in "${ROADSENSE_PRODUCTION_API_HOSTS[@]}"; do
        if [[ "${host}" == "${known}" ]]; then
            return 0
        fi
    done
    return 1
}
