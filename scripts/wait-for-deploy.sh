#!/usr/bin/env bash
#
# Poll the API's /health until it reports the expected git commit, so smoke
# tests run against the new deployment rather than the one it replaces.
#
# Usage:
#   FUNCTIONS_BASE_URL=https://api.nsroadsense.ca/functions/v1 PUBLIC_API_KEY=... \
#     scripts/wait-for-deploy.sh <expected-commit-sha> [timeout-seconds]
#
# /health reports the first of RAILWAY_GIT_COMMIT_SHA (GitHub-triggered
# Railway deploys), GIT_COMMIT_SHA and GIT_SHA. Deploys made with `railway up`
# must set GIT_COMMIT_SHA first; see
# docs/implementation/05-deployment-and-observability.md.

set -euo pipefail

EXPECTED_COMMIT="${1:-}"
TIMEOUT_SECONDS="${2:-900}"
INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-15}"
FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL:-}"
API_KEY="${PUBLIC_API_KEY:-${SUPABASE_ANON_KEY:-}}"

if [[ ! "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "Usage: $0 <expected-commit-sha> [timeout-seconds]" >&2
    exit 2
fi
if [[ ! "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ || ! "${INTERVAL_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "timeout and WAIT_INTERVAL_SECONDS must be whole seconds" >&2
    exit 2
fi
if [[ -z "${FUNCTIONS_BASE_URL}" || -z "${API_KEY}" ]]; then
    echo "FUNCTIONS_BASE_URL and PUBLIC_API_KEY (or SUPABASE_ANON_KEY) are required" >&2
    exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

deadline=$((SECONDS + TIMEOUT_SECONDS))
echo "→ Waiting up to ${TIMEOUT_SECONDS}s for ${FUNCTIONS_BASE_URL}/health to report commit ${EXPECTED_COMMIT}"

while :; do
    status="$(curl -sS -o "${tmp}" -w '%{http_code}' --max-time 15 \
        -H "apikey: ${API_KEY}" \
        -H "Authorization: Bearer ${API_KEY}" \
        "${FUNCTIONS_BASE_URL}/health" 2>/dev/null || true)"

    deployed=""
    if [[ "${status}" == "200" ]]; then
        deployed="$(python3 -c '
import json, re, sys
try:
    commit = str(json.load(open(sys.argv[1])).get("commit", ""))
except Exception:
    commit = ""
print(commit if re.fullmatch(r"[0-9A-Za-z._-]{1,64}", commit) else "")
' "${tmp}")"
    fi

    # Accept a short SHA on either side (at least 7 characters).
    if [[ "${#deployed}" -ge 7 ]] && [[ "${deployed}" == "${EXPECTED_COMMIT}"* || "${EXPECTED_COMMIT}" == "${deployed}"* ]]; then
        echo "→ Deployed: ${deployed}"
        exit 0
    fi

    if (( SECONDS >= deadline )); then
        echo "Timed out: /health last returned HTTP ${status:-none}, commit '${deployed:-unknown}', expected ${EXPECTED_COMMIT}." >&2
        exit 1
    fi
    echo "  HTTP ${status:-none}, commit '${deployed:-unknown}'; retrying in ${INTERVAL_SECONDS}s"
    sleep "${INTERVAL_SECONDS}"
done
