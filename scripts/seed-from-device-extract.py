#!/usr/bin/env python3
"""Seed Railway Postgres with readings + manual marks pulled from a personal
device extract.

Usage:
    export ROAD_SENSE_TOKEN_PEPPER="$(grep ^TOKEN_PEPPER= .railway-secrets.local | cut -d= -f2-)"
    python3 scripts/seed-from-device-extract.py --dry-run
    python3 scripts/seed-from-device-extract.py --yes

Calls the target database stored procedures directly via psql, bypassing the
HTTP rate limit that makes the public /upload-readings endpoint impractical
for bulk historical seeding. Still hits the same validation rules
(staleness, speed, segment match) — anything older than 7 days, slower
than 15 km/h, or off the matched road network is rejected on purpose.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent
EXTRACT_DIR = REPO_ROOT / ".context" / "device-extract"
READINGS_TSV = EXTRACT_DIR / "all_readings.tsv"
MARKS_TSV = EXTRACT_DIR / "manual_marks_full.tsv"

BATCH_SIZE = 500
DEFAULT_GPS_ACCURACY_M = 5.0
DEFAULT_HEADING_DEG = 0.0
CLIENT_APP_VERSION = "0.1.0-seed"
CLIENT_OS_VERSION = "iOS 18.0"

PSQL_CANDIDATES = [
    "/opt/homebrew/opt/libpq/bin/psql",
    "/usr/local/opt/libpq/bin/psql",
    "psql",
]


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def find_psql() -> str:
    for candidate in PSQL_CANDIDATES:
        path = shutil.which(candidate) if "/" not in candidate else (candidate if Path(candidate).exists() else None)
        if path:
            return path
    die("psql not found; install libpq via brew or set the path manually")


def hex_to_uuid(hex32: str) -> str:
    h = hex32.strip().replace("-", "").lower()
    if len(h) != 32:
        raise ValueError(f"expected 32 hex chars, got {len(h)}: {hex32!r}")
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def deterministic_uuid_v4(seed: str) -> str:
    digest = hashlib.sha1(seed.encode()).hexdigest()
    chars = list(digest[:32])
    chars[12] = "4"
    if chars[16] not in ("8", "9", "a", "b"):
        chars[16] = "8"
    h = "".join(chars)
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def device_token_hash_hex(device_token: str, pepper: str) -> str:
    return hashlib.sha256(f"{device_token}{pepper}".encode()).hexdigest()


def unix_to_iso(unix_ts: float) -> str:
    return datetime.fromtimestamp(unix_ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def parse_optional_float(value: str) -> float | None:
    if value in ("", "NULL", None):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def load_readings() -> list[dict]:
    if not READINGS_TSV.exists():
        die(f"missing extract: {READINGS_TSV}")
    rows: list[dict] = []
    for line in READINGS_TSV.open():
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 8:
            continue
        try:
            ts = float(parts[0])
            lat = float(parts[1])
            lng = float(parts[2])
        except ValueError:
            continue
        rms = parse_optional_float(parts[3])
        if rms is None:
            continue
        speed = parse_optional_float(parts[5]) or 0.0
        device_hex = parts[7].strip()
        if not device_hex:
            continue
        rows.append({
            "ts": ts,
            "lat": lat,
            "lng": lng,
            "rms": rms,
            "mag": parse_optional_float(parts[4]),
            "speed": speed,
            "is_pothole": parts[6] == "1",
            "device_hex": device_hex,
        })
    rows.sort(key=lambda r: (r["device_hex"], r["ts"]))
    return rows


def load_marks() -> list[dict]:
    if not MARKS_TSV.exists():
        die(f"missing extract: {MARKS_TSV}")
    rows: list[dict] = []
    for line in MARKS_TSV.open():
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 5:
            continue
        try:
            ts = float(parts[0])
            lat = float(parts[1])
            lng = float(parts[2])
        except ValueError:
            continue
        device_hex = parts[4].strip()
        if not device_hex:
            continue
        rows.append({"ts": ts, "lat": lat, "lng": lng, "device_hex": device_hex})
    return rows


def chunked(items: list, size: int) -> Iterable[list]:
    for i in range(0, len(items), size):
        yield items[i:i + size]


def run_psql(psql_path: str, db_url: str, sql: str) -> str:
    env = os.environ.copy()
    env["PGDATABASE"] = db_url
    proc = subprocess.run(
        [psql_path, "-v", "ON_ERROR_STOP=1", "-At", "-c", sql],
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def get_db_url() -> str:
    url = os.environ.get("DATABASE_URL", "").strip()
    if url:
        return url
    proc = subprocess.run(
        ["railway", "run", "--service", "PostGIS", "sh", "-c", "echo $DATABASE_URL"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        die(f"could not resolve DATABASE_URL: {proc.stderr.strip()}")
    lines = [ln for ln in proc.stdout.splitlines() if ln.startswith("postgres://")]
    if not lines:
        die("no postgres URL found in `railway run` output")
    return lines[-1]


def seed_readings(psql_path: str, db_url: str, pepper: str, readings: list[dict], dry_run: bool) -> tuple[int, int]:
    accepted = 0
    rejected = 0
    by_device: dict[str, list[dict]] = {}
    for r in readings:
        by_device.setdefault(r["device_hex"], []).append(r)

    for device_hex, rows in by_device.items():
        device_token = hex_to_uuid(device_hex)
        token_hash = device_token_hash_hex(device_token, pepper)
        for batch_index, batch in enumerate(chunked(rows, BATCH_SIZE)):
            seed = f"seed:{device_hex}:{batch[0]['ts']:.3f}:{batch[-1]['ts']:.3f}:{len(batch)}"
            batch_id = deterministic_uuid_v4(seed)
            readings_json = json.dumps([
                {
                    "lat": r["lat"],
                    "lng": r["lng"],
                    "roughness_rms": r["rms"],
                    "speed_kmh": r["speed"],
                    "heading": DEFAULT_HEADING_DEG,
                    "gps_accuracy_m": DEFAULT_GPS_ACCURACY_M,
                    "is_pothole": r["is_pothole"],
                    "pothole_magnitude": r["mag"],
                    "recorded_at": unix_to_iso(r["ts"]),
                }
                for r in batch
            ])
            sql = (
                "SELECT ingest_reading_batch("
                f"  $${batch_id}$$::uuid, "
                f"  decode($${token_hash}$$, 'hex')::bytea, "
                f"  $${readings_json.replace('$', '\\$')}$$::jsonb, "
                f"  now(), $$0.1.0-seed$$, $$iOS 18.0$$)"
                ";"
            )
            print(f"  device {device_hex[:8]}.. batch {batch_index + 1} ({len(batch)} readings)", flush=True)
            if dry_run:
                accepted += len(batch)
                continue
            try:
                result = run_psql(psql_path, db_url, sql)
                parsed = json.loads(result)
                accepted += int(parsed.get("accepted", 0))
                rejected += int(parsed.get("rejected", 0))
                if parsed.get("duplicate"):
                    print(f"    -> duplicate batch (server already has {batch_id})", flush=True)
                if parsed.get("rejected_reasons"):
                    print(f"    -> rejected: {parsed['rejected_reasons']}", flush=True)
            except Exception as exc:
                print(f"    -> FAILED: {exc}", flush=True)
    return accepted, rejected


def seed_marks(psql_path: str, db_url: str, pepper: str, marks: list[dict], dry_run: bool) -> int:
    sent = 0
    for mark in marks:
        device_token = hex_to_uuid(mark["device_hex"])
        token_hash = device_token_hash_hex(device_token, pepper)
        seed = f"seed-mark:{mark['device_hex']}:{mark['ts']:.6f}:{mark['lat']:.6f}:{mark['lng']:.6f}"
        action_id = deterministic_uuid_v4(seed)
        recorded_at_iso = unix_to_iso(mark["ts"])
        sql = (
            "SELECT apply_pothole_action("
            f"  $${action_id}$$::uuid, "
            f"  decode($${token_hash}$$, 'hex')::bytea, "
            f"  $$manual_report$$::pothole_action_type, "
            f"  {mark['lat']}::double precision, "
            f"  {mark['lng']}::double precision, "
            f"  {DEFAULT_GPS_ACCURACY_M}::numeric, "
            f"  $${recorded_at_iso}$$::timestamptz, "
            f"  NULL::uuid)"
            ";"
        )
        print(f"  mark @ {mark['lat']:.4f},{mark['lng']:.4f} ({recorded_at_iso})", flush=True)
        if dry_run:
            sent += 1
            continue
        try:
            run_psql(psql_path, db_url, sql)
            sent += 1
        except Exception as exc:
            print(f"    -> FAILED: {exc}", flush=True)
    return sent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true", help="actually write to the target database")
    parser.add_argument("--readings-only", action="store_true")
    parser.add_argument("--marks-only", action="store_true")
    args = parser.parse_args()

    if args.readings_only and args.marks_only:
        die("--readings-only and --marks-only are mutually exclusive")

    if not args.dry_run and not args.yes:
        die("refusing to write without --yes; use --dry-run to inspect the extract")

    pepper = os.environ.get("ROAD_SENSE_TOKEN_PEPPER", "").strip()
    if not args.dry_run and not pepper:
        die("ROAD_SENSE_TOKEN_PEPPER is required (read from .railway-secrets.local).")

    psql_path = "" if args.dry_run else find_psql()
    db_url = "" if args.dry_run else get_db_url()

    if not args.marks_only:
        readings = load_readings()
        print(f"loaded {len(readings)} readings from {READINGS_TSV.relative_to(REPO_ROOT)}")
        if readings:
            accepted, rejected = seed_readings(psql_path, db_url, pepper, readings, args.dry_run)
            print(f"readings: accepted={accepted} rejected={rejected}")

    if not args.readings_only:
        marks = load_marks()
        print(f"loaded {len(marks)} manual marks from {MARKS_TSV.relative_to(REPO_ROOT)}")
        if marks:
            sent = seed_marks(psql_path, db_url, pepper, marks, args.dry_run)
            print(f"marks: sent={sent}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
