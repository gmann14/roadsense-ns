#!/usr/bin/env bash
#
# After a calibration drive, pull the iOS app's data container off a paired
# iPhone and refresh .context/device-live-latest in one step. Then optionally
# run the quality report so deltas surface immediately.
#
# Usage:
#   ./scripts/pull-device-store.sh                # pull + run report
#   ./scripts/pull-device-store.sh --no-report    # pull only
#   ./scripts/pull-device-store.sh --device <id>  # explicit device id
#   ./scripts/pull-device-store.sh --bundle <id>  # explicit app bundle id
#
# Defaults match Local Debug iPhone builds (ca.roadsense.ios.localdebug).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEVICE_ID=""
BUNDLE_ID="ca.roadsense.ios.localdebug"
RUN_REPORT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "--device requires a value" >&2; exit 2; }
      DEVICE_ID="$2"; shift 2 ;;
    --bundle)
      [[ $# -ge 2 ]] || { echo "--bundle requires a value" >&2; exit 2; }
      BUNDLE_ID="$2"; shift 2 ;;
    --no-report)
      RUN_REPORT=0; shift ;;
    -h|--help)
      sed -n '3,15p' "$0"; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found — install Xcode Command Line Tools" >&2
  exit 1
fi

# If no device id was passed, pick the first paired/available device.
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/available \(paired\)/ { print $(NF-2); exit }')"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "No paired iOS device found. Connect the phone, unlock it, and trust the Mac." >&2
    echo "Or pass --device <identifier> from \`xcrun devicectl list devices\`." >&2
    exit 1
  fi
fi

TS="$(date +%Y%m%d-%H%M%S)"
PULL_DIR=".context/device-pull-${TS}"
LIVE_DIR=".context/device-live-latest"
LIVE_STORE_DIR="${LIVE_DIR}/Library/Application Support"
SNAPSHOT_FILE="${LIVE_STORE_DIR}/default.store.report-snapshot"

mkdir -p "$PULL_DIR"

echo "→ Pulling app data container for ${BUNDLE_ID}"
echo "  device: ${DEVICE_ID}"
echo "  dest:   ${PULL_DIR}"

xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source "Library/Application Support/" \
  --destination "${PULL_DIR}/" >/dev/null

if [[ ! -f "${PULL_DIR}/default.store" ]]; then
  echo "Pull completed but ${PULL_DIR}/default.store is missing." >&2
  echo "Listing what was copied:" >&2
  ls -la "${PULL_DIR}" >&2
  exit 1
fi

echo "→ Refreshing device-live-latest, preserving any existing report snapshot"
TMP_SNAPSHOT="$(mktemp -d)"
trap 'rm -rf "$TMP_SNAPSHOT"' EXIT
if [[ -f "$SNAPSHOT_FILE" ]]; then
  cp "$SNAPSHOT_FILE" "${TMP_SNAPSHOT}/snap"
fi

rm -rf "$LIVE_DIR"
mkdir -p "$LIVE_STORE_DIR"
cp "${PULL_DIR}/default.store" "$LIVE_STORE_DIR/"
[[ -f "${PULL_DIR}/default.store-shm" ]] && cp "${PULL_DIR}/default.store-shm" "$LIVE_STORE_DIR/"
[[ -f "${PULL_DIR}/default.store-wal" ]] && cp "${PULL_DIR}/default.store-wal" "$LIVE_STORE_DIR/"
[[ -f "${PULL_DIR}/SensorCheckpoint.json" ]] && cp "${PULL_DIR}/SensorCheckpoint.json" "$LIVE_STORE_DIR/"

if [[ -f "${TMP_SNAPSHOT}/snap" ]]; then
  cp "${TMP_SNAPSHOT}/snap" "$SNAPSHOT_FILE"
  echo "  preserved prior snapshot for delta"
else
  echo "  no prior snapshot — this run will be the new baseline"
fi

echo "$PULL_DIR" > .context/latest-device-pull-path

echo ""
echo "✓ pulled to ${PULL_DIR}"
echo "✓ wired into ${LIVE_DIR}"
echo ""

if [[ "$RUN_REPORT" -eq 1 ]]; then
  echo "→ Running local-ios-quality-report.sh"
  echo ""
  "${ROOT_DIR}/scripts/local-ios-quality-report.sh"
fi
