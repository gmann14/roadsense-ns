#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$ROOT_DIR/ios/Config/RoadSenseNS.Local.secrets.xcconfig"
PORT="${PORT:-3000}"
HOST="${HOST:-127.0.0.1}"
API_BASE_URL="${NEXT_PUBLIC_API_BASE_URL:-http://127.0.0.1:54321/functions/v1}"

read_xcconfig_value() {
  local key="$1"
  awk -F'=' -v target="$key" '
    $1 ~ "^[[:space:]]*" target "[[:space:]]*$" {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$SECRETS_FILE"
}

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "missing secrets file: $SECRETS_FILE" >&2
  exit 1
fi

export NEXT_PUBLIC_MAPBOX_TOKEN="${NEXT_PUBLIC_MAPBOX_TOKEN:-$(read_xcconfig_value MAPBOX_ACCESS_TOKEN)}"
export NEXT_PUBLIC_SUPABASE_ANON_KEY="${NEXT_PUBLIC_SUPABASE_ANON_KEY:-$(read_xcconfig_value SUPABASE_ANON_KEY)}"
export NEXT_PUBLIC_API_BASE_URL="$API_BASE_URL"

if [[ -z "${NEXT_PUBLIC_MAPBOX_TOKEN}" || -z "${NEXT_PUBLIC_SUPABASE_ANON_KEY}" ]]; then
  echo "missing NEXT_PUBLIC_MAPBOX_TOKEN or NEXT_PUBLIC_SUPABASE_ANON_KEY" >&2
  exit 1
fi

cd "$ROOT_DIR/apps/web"
echo "Starting local web map on http://$HOST:$PORT"
echo "Using API base: $NEXT_PUBLIC_API_BASE_URL"
npm run dev -- --hostname "$HOST" --port "$PORT"
