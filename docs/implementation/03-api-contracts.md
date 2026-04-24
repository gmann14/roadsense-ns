# 03 — API Contracts

*Last updated: 2026-04-17*

Authoritative request/response shapes for all endpoints. **Lock this doc by end of week 2** so iOS and backend can work in parallel without churn.

## Conventions

- Base URL: `https://<project-ref>.supabase.co/functions/v1`
- Content-Type: `application/json` for JSON endpoints, `application/vnd.mapbox-vector-tile` for tiles
- Auth: Supabase anon key in `Authorization: Bearer <anon>` header for all requests except `GET /health`, which is intentionally unauthenticated for uptime monitoring. Supabase Edge Functions require the Authorization header; the `apikey` header is also accepted for compatibility. No custom auth headers — app version / OS version live in the JSON body on upload endpoints where they're relevant.
- The `ingest_reading_batch` RPC is `SECURITY DEFINER` with `EXECUTE` granted only to `service_role`; the anon key cannot invoke it directly. Uploads MUST go through the `/functions/v1/upload-readings` Edge Function, which holds the service role key and enforces rate limits before dispatching.
- All timestamps are RFC 3339 / ISO 8601 with timezone (`2026-04-17T14:30:00Z`)
- All coordinates are WGS84 (EPSG:4326), `lng` then `lat` where ordered, but JSON fields are named explicitly (`lat`, `lng`) to avoid ambiguity
- UUIDs are lowercase v4 strings with hyphens
- Sizes in meters; speeds in km/h; no mixed units anywhere

## Versioning

- Single major version for MVP: no `/v1/` prefix needed yet
- Breaking changes: new endpoint path, not header-based versioning
- Non-breaking additions (new optional fields) are free to add; clients must ignore unknown fields

## Error Envelope

All 4xx and 5xx responses return:

```json
{
    "error": "rate_limited",
    "message": "Too many upload batches from this device in the last 24h.",
    "retry_after_s": 3600,
    "request_id": "01H9Z..."
}
```

Standard error codes:

| Code | HTTP | Meaning |
|---|---|---|
| `validation_failed` | 400 | Payload shape or values invalid. `message` enumerates violations. |
| `batch_too_large` | 400 | `readings` exceeded 1000. |
| `unauthorized` | 401 | Missing/invalid anon key. |
| `forbidden` | 403 | Using wrong key (e.g., trying to hit a service-role endpoint). |
| `not_found` | 404 | Segment/pothole/etc. doesn't exist. |
| `rate_limited` | 429 | Per-device or per-IP limit hit. |
| `processing_failed` | 502 | Stored procedure errored. Transient; client should retry. |
| `service_unavailable` | 503 | Maintenance / upstream issue. |

Every response includes `x-request-id` header for support/debugging. Client logs this on failure.

## Endpoints

### `POST /upload-readings`

Batch upload of processed point readings.

**Request**

```json
{
    "batch_id": "b5f6a3c2-8e10-4d1f-9a7b-0e2c6d4f8a31",
    "device_token": "a78f9e2b-4c6d-11ec-81d3-0242ac130003",
    "client_sent_at": "2026-04-17T14:30:00Z",
    "client_app_version": "0.1.3 (42)",
    "client_os_version": "iOS 17.4.1",
    "readings": [
        {
            "lat": 44.6488,
            "lng": -63.5752,
            "roughness_rms": 0.47,
            "speed_kmh": 62.3,
            "heading": 184.5,
            "gps_accuracy_m": 6.5,
            "recorded_at": "2026-04-17T14:28:14.321Z",
            "is_pothole": false,
            "pothole_magnitude": null
        }
    ]
}
```

**Notes**

- `batch_id` must be UUIDv4, generated on client. Server uses it for idempotency — retried uploads with the same `batch_id` replay the original `{accepted, rejected, duplicate, rejected_reasons}` result.
- `device_token` is a UUIDv4 generated on client, rotated monthly. It is sent over TLS to the Edge Function, hashed there with a server-side pepper, and discarded. The raw token is never persisted.
- `readings.length ≤ 1000`. Larger → `batch_too_large` error; client must split.
- Hard 400s are only for malformed payloads: missing required fields, non-UUID `batch_id` / `device_token`, non-numeric scalar fields, or `batch_too_large`.
- Domain-level bad readings are soft-rejected and counted in `rejected_reasons` with a 200 response. That includes stale/future timestamps, out-of-bounds coordinates, low-quality readings, unpaved matches, and no-match cases.

**Response — 200 OK**

```json
{
    "batch_id": "b5f6a3c2-8e10-4d1f-9a7b-0e2c6d4f8a31",
    "accepted": 48,
    "rejected": 2,
    "duplicate": false,
    "rejected_reasons": {
        "out_of_bounds": 1,
        "no_segment_match": 1
    }
}
```

- `accepted`: number of readings persisted to `readings` table
- `rejected`: `readings.length - accepted`
- `duplicate`: `true` if this `batch_id` was already processed (no-op retry)
- `rejected_reasons`: counts by reason code. Only codes the server actually emits are listed — clients must tolerate unknown keys for forward-compat. MVP-emitted enum:
  - `out_of_bounds` — lat/lng outside NS bbox
  - `no_segment_match` — no road segment within 25m / heading window
  - `low_quality` — server-visible quality gates failed (`gps_accuracy_m > 20`, `speed_kmh < 15`, `speed_kmh > 160`, or `roughness_rms` outside `[0, 15]`). Client-only gates such as `duration_s > 15` and `sample_count < 30` should have been dropped before upload and never reach the backend.
  - `future_timestamp` — `recorded_at` in the future by > 60s
  - `stale_timestamp` — `recorded_at` older than 7 days
  - `unpaved` — matched segment surface is non-paved in OSM

**Intentionally removed from MVP:**
- `invalid_value` — a full-batch `validation_failed` is returned instead; there is no per-reading "accepted-but-flagged" path.
- `privacy_zone` — privacy zones live only on-device. Server has no knowledge of any user's zones and so cannot emit this code. Defense-in-depth here would require a separate mechanism (e.g., client attestation of a canonical public-zone list) and is deferred.

**Response — 400 validation_failed**

```json
{
    "error": "validation_failed",
    "message": "Payload is malformed.",
    "field_errors": {
        "device_token": "must be a UUIDv4 string",
        "readings[3].roughness_rms": "must be numeric"
    },
    "request_id": "01H9Z..."
}
```

**Response — 429 rate_limited**

```json
{
    "error": "rate_limited",
    "message": "Device exceeded 50 batches in 24h window.",
    "retry_after_s": 3600,
    "request_id": "01H9Z..."
}
```

Also sets `Retry-After: 3600` header.

---

### `GET /tiles/{z}/{x}/{y}.mvt`

Vector tile with road quality overlays and pothole markers.

**Request**

- URL params: `z` (zoom), `x` (tile col), `y` (tile row)
- Optional query: `?v=<int>` for cache-busting (daily rotation)
- Headers: `apikey`, `Authorization`

**Response — 200 OK**

- `Content-Type: application/vnd.mapbox-vector-tile`
- `Cache-Control: public, max-age=3600, s-maxage=3600`
- Body: binary MVT containing two source layers:

**source-layer: `segment_aggregates`** (type: LineString)

| Attribute | Type | Meaning |
|---|---|---|
| `id` | string (UUID) | segment_id |
| `road_name` | string? | from OSM |
| `road_type` | string | motorway, primary, ... |
| `roughness_score` | float | 0–2.0 typical range |
| `category` | string | smooth, fair, rough, very_rough, unpaved |
| `confidence` | string | low, medium, high (low is filtered out) |
| `total_readings` | int | |
| `unique_contributors` | int | |
| `pothole_count` | int | |

**source-layer: `potholes`** (type: Point)

| Attribute | Type | Meaning |
|---|---|---|
| `id` | string (UUID) | |
| `magnitude` | float | g-force |
| `confirmation_count` | int | |

**Response — 204 No Content** if tile has no data at this zoom. Response still carries cache headers.

---

### `GET /segments/{id}`

Single segment detail for tap-on-road modal.

**Request**

- `id` path param (UUID)

**Response — 200 OK**

```json
{
    "id": "c8a1b2d3-...",
    "road_name": "Barrington Street",
    "road_type": "primary",
    "municipality": "Halifax",
    "length_m": 48.7,
    "has_speed_bump": false,
    "has_rail_crossing": false,
    "surface_type": "asphalt",
    "aggregate": {
        "avg_roughness_score": 0.72,
        "category": "rough",
        "confidence": "high",
        "total_readings": 137,
        "unique_contributors": 34,
        "pothole_count": 2,
        "trend": "worsening",
        "score_last_30d": 0.78,
        "score_30_60d": 0.69,
        "last_reading_at": "2026-04-16T22:15:00Z",
        "updated_at": "2026-04-17T03:15:00Z"
    },
    "history": [],
    "neighbors": null
}
```

**Scope note (MVP):** `history` and `neighbors` ship as empty/null stubs for the MVP because neither has a cheap backing query. Clients must handle empty arrays and null objects gracefully.

Post-MVP plan:
- `history`: add a `segment_history_monthly` materialized view keyed `(segment_id, month)`, refreshed by the nightly recompute job. Cheap to query, 12 rows per segment max.
- `neighbors`: derivable from `road_segments (osm_way_id, segment_index)` via `±1` lookup once a unique index on that pair is in place (the schema already has one in Migration 002).

**Response — 404 not_found** if no aggregate exists for this segment yet.

---

### `GET /potholes?bbox=<minLng>,<minLat>,<maxLng>,<maxLat>`

List active potholes in a bounding box. Used for the pothole marker overlay when the user requests more detail than the tile provides (e.g., list view).

**Response — 200 OK**

```json
{
    "potholes": [
        {
            "id": "p1-...",
            "lat": 44.6498,
            "lng": -63.5762,
            "magnitude": 2.4,
            "confirmation_count": 7,
            "first_reported_at": "2026-04-01T12:00:00Z",
            "last_confirmed_at": "2026-04-16T08:00:00Z",
            "status": "active",
            "segment_id": "c8a1b2d3-..."
        }
    ]
}
```

Bbox limited to ~10km × 10km; larger requests return 400.

---

### `GET /stats`

Public global stats for the stats card on the home screen.

**Response — 200 OK**

```json
{
    "total_km_mapped": 18423.7,
    "total_readings": 1873921,
    "segments_scored": 28743,
    "active_potholes": 213,
    "municipalities_covered": 4,
    "generated_at": "2026-04-17T14:00:00Z"
}
```

Cache-Control: `public, max-age=300`. Computed from a materialized view refreshed every 5 minutes by `pg_cron`.

---

### `GET /health`

Liveness + basic readiness.

**Response — 200 OK**

```json
{
    "status": "ok",
    "version": "1.0.3",
    "commit": "a1b2c3d",
    "deployed_at": "2026-04-10T18:00:00Z",
    "db": "reachable"
}
```

Unauthenticated. Used by uptime monitoring.

---

## Phase 2 Web Dashboard Endpoints

These are not part of the iOS/TestFlight MVP, but they are required for the public web dashboard defined in [07-web-dashboard-implementation.md](07-web-dashboard-implementation.md).

### `GET /tiles/coverage/{z}/{x}/{y}.mvt`

Coverage tile for the public web `Coverage` mode.

Use this instead of the normal quality tile when the UI is answering: "where do we have enough community data?" The standard tile endpoint is intentionally not enough because it hides low-confidence and unscored roads.

**Request**

- URL params: `z` (zoom), `x` (tile col), `y` (tile row)
- Optional query: `?v=<int>` for cache-busting (daily rotation)
- Headers: `apikey`, `Authorization`

**Response — 200 OK**

- `Content-Type: application/vnd.mapbox-vector-tile`
- `Cache-Control: public, max-age=3600, s-maxage=3600`
- Body: binary MVT containing source-layer `segment_coverage`

| Attribute | Type | Meaning |
|---|---|---|
| `id` | string (UUID) | segment_id |
| `road_name` | string? | from OSM |
| `road_type` | string | motorway, primary, ... |
| `coverage_level` | string | `none`, `emerging`, `published`, `strong` |
| `updated_at` | string? | last aggregate refresh time when available |

**Coverage-level derivation**

- `none` — no aggregate row or `total_readings = 0`
- `emerging` — aggregate exists but `unique_contributors < 3`
- `published` — `unique_contributors >= 3` and `< 10`
- `strong` — `unique_contributors >= 10`

**Privacy note:** do not include raw `total_readings` or `unique_contributors` on `none` / `emerging` segments. The web only needs a public coverage tier, not low-sample counts.

**Response — 204 No Content** if tile has no data at this zoom. Response still carries cache headers.

---

### `GET /segments/worst?municipality=<name>&limit=<n>`

Top-N roughest published segments for the web `Worst Roads` report.

**Request**

- `municipality` optional exact municipality display name
- `limit` required integer, `1 <= limit <= 100`

**Ranking semantics**

- published roads only (`unique_contributors >= 3`, confidence not low)
- exclude `unscored`
- exclude `unpaved`
- sort by `avg_roughness_score DESC`, then `pothole_count DESC`, then `total_readings DESC`

**Response — 200 OK**

```json
{
    "generated_at": "2026-04-17T03:20:00Z",
    "municipality": "Halifax",
    "rows": [
        {
            "rank": 1,
            "segment_id": "c8a1b2d3-...",
            "road_name": "Barrington Street",
            "municipality": "Halifax",
            "road_type": "primary",
            "category": "very_rough",
            "confidence": "high",
            "avg_roughness_score": 1.181,
            "score_last_30d": 1.242,
            "score_30_60d": 1.011,
            "trend": "worsening",
            "total_readings": 182,
            "unique_contributors": 37,
            "pothole_count": 3,
            "last_reading_at": "2026-04-16T22:15:00Z"
        }
    ]
}
```

**Response — 400 validation_failed**

- invalid municipality name
- invalid or missing `limit`

## Client-side Behavior Expectations

### Upload Retry

- Network error or 5xx: exponential backoff 1s, 2s, 4s, 8s, 16s, max 5 attempts
- 429: respect `Retry-After` header (fallback to 60s if missing)
- 400 `validation_failed`: do NOT retry. Mark batch as `failed_permanent` in local queue and surface in Settings. Log fields.
- 200: mark batch `succeeded`; on next queue tick, delete readings older than 30 days

### Idempotency Contract

Client MUST use the same `batch_id` for retries of the same batch. Changing `batch_id` on retry creates duplicate data.

### Tile Caching

- Mapbox SDK handles HTTP cache respect automatically
- Force-refresh after user taps "Refresh" on settings: bump the `v=` query param on the tile URL
- Offline packs download at zoom 10–16 for HRM on first launch; use Mapbox `OfflineManager`

### Device Token Rotation

- Client rotates on the first app launch after the 1st of each month
- Old token is not persisted; new token replaces it immediately
- Server receives the cleartext token over TLS at upload time, hashes it inside the Edge Function, persists only the hash, and discards the cleartext immediately

## Additional Endpoints Beyond The Passive-MVP Loop

These endpoints sit outside the narrow passive-collection MVP loop. Some are already implemented for the internal build; others remain deferred but are specified here so the contract shape is locked.

- `GET /segments/export?bbox=...&format=geojson|kml` — data export
- `POST /pothole-actions` — explicit pothole mark / still-there / looks-fixed actions; implemented for the manual `Mark pothole` flow, segment-detail follow-up UI, and stopped-only expiring prompt actions
- `POST /pothole-photos` — photo metadata + signed-upload initiation; implemented for the first photo-reporting pass
- `GET /coverage?municipality=<name>` — coverage % by municipality
- `GET /contributors/me` — personal stats authenticated via device token (requires token-signing flow, out of scope for MVP)

### `POST /pothole-actions` (manual pothole reports + follow-up)

One-tap pothole report endpoint plus follow-up actions against existing pothole markers. Matches [01-ios-implementation.md §Manual Pothole Reporting And Follow-up](01-ios-implementation.md) and [02-backend-implementation.md §Explicit Pothole Actions](02-backend-implementation.md).

**Request**

```json
{
    "action_id": "d89fe2a5-6b3f-4207-a592-5fe67bb4b6ff",
    "device_token": "a78f9e2b-4c6d-11ec-81d3-0242ac130003",
    "client_sent_at": "2026-04-21T18:22:05Z",
    "client_app_version": "0.2.0 (78)",
    "client_os_version": "iOS 17.4.1",
    "action_type": "manual_report",
    "pothole_report_id": null,
    "lat": 44.6488,
    "lng": -63.5752,
    "accuracy_m": 6.8,
    "recorded_at": "2026-04-21T18:22:00Z"
}
```

**Notes**

- `action_id` is the idempotency key. Repeating the exact same action returns the same canonical result.
- `action_type` values: `manual_report`, `confirm_present`, `confirm_fixed`.
- `pothole_report_id` is required for `confirm_present` and `confirm_fixed`, omitted for `manual_report`.
- `lat` / `lng` are the precise client coordinates after privacy-zone filtering. Do not randomize them.
- repeating the same action type from the same device against the same pothole within 24 hours may return `200` without incrementing public counters again

**Response — 200 OK**

```json
{
    "action_id": "d89fe2a5-6b3f-4207-a592-5fe67bb4b6ff",
    "pothole_report_id": "0bb4e4af-c1a0-4c1f-9c19-4ef1f0f6f420",
    "status": "active",
    "request_id": "01H9Z..."
}
```

`status` is the canonical pothole status after the action is applied. Most `manual_report` and `confirm_present` calls return `active`; `confirm_fixed` may return either `active` or `resolved` depending on quorum.

**Response — 409 stale_target**

```json
{
    "error": "stale_target",
    "message": "This pothole marker no longer matches your current location.",
    "request_id": "01H9Z..."
}
```

**Response — 429 rate_limited**

Pothole actions have a dedicated bucket: 60 / 24h per device token hash, 120 / 1h per IP. See [02-backend-implementation.md §Pothole Action Rate Limits](02-backend-implementation.md).

### `POST /pothole-photos` (post-MVP — photo capture)

Two-step signed-URL upload for pothole photos. Matches [01-ios-implementation.md §Pothole Photo Capture](01-ios-implementation.md) and [02-backend-implementation.md §Pothole Photo Moderation](02-backend-implementation.md).

**Request**

```json
{
    "report_id": "c2f1a4b3-1234-4c5d-8e9f-112233445566",
    "segment_id": "92abed15-d273-4bd3-92ec-d4f0c8b82f99",
    "device_token": "a78f9e2b-4c6d-11ec-81d3-0242ac130003",
    "client_sent_at": "2026-04-21T18:22:05Z",
    "client_app_version": "0.2.0 (78)",
    "client_os_version": "iOS 17.4.1",
    "lat": 44.6488,
    "lng": -63.5752,
    "accuracy_m": 6.8,
    "captured_at": "2026-04-21T18:22:00Z",
    "content_type": "image/jpeg",
    "byte_size": 312840,
    "sha256": "9b74c9897bac770ffc029102a200c5de"
}
```

**Notes**

- `report_id` is a client-generated UUIDv4 and is the idempotency key. Retrying the call with the same `report_id` while the row is still `pending_upload` returns a fresh signed URL for the same object path. Once the object already exists, the endpoint returns `409 already_uploaded`.
- `segment_id` is optional. Clients send it when the capture flow was scoped from a segment detail view; otherwise send `null` or omit it.
- `content_type` must be `image/jpeg` (only accepted value in MVP).
- `byte_size` must be ≤ 1,500,000. Client target is ≤ 400 KB.
- `sha256` is the hex-encoded SHA-256 of the exact bytes the client will PUT.
- `lat` / `lng` are the precise client coordinates after privacy-zone filtering. Do not randomize them.
- accepted photos join the same merged `pothole_reports` cluster model used by passive spikes and `POST /pothole-actions`

**Response — 200 OK**

```json
{
    "report_id": "c2f1a4b3-1234-4c5d-8e9f-112233445566",
    "upload_url": "https://...supabase.co/storage/v1/object/sign/pothole-photos/pending/c2f1a4b3-...jpg?token=...",
    "upload_expires_at": "2026-04-21T20:22:05Z",
    "expected_object_path": "pending/c2f1a4b3-....jpg"
}
```

Client then `PUT`s the JPEG bytes to `upload_url` directly. The Storage service enforces byte size, content type, path pattern, and single-write semantics on the signed upload path. Clients must treat the URL as ephemeral and restart from the metadata POST after interruption instead of persisting it.

`upload_expires_at` is currently emitted as a ~2 hour window to match Supabase signed-upload URL behavior. The client must still treat it as ephemeral and restart from the metadata POST after interruption instead of persisting signed URLs.

**Response — 409 already_uploaded**

```json
{
    "error": "already_uploaded",
    "message": "This report_id has already been submitted.",
    "request_id": "01H9Z..."
}
```

Client treats this as success (report is on the server, local cleanup can proceed).

**Response — 429 rate_limited**

Photo submissions have a dedicated bucket: 20 / 24h per device token hash, 40 / 1h per IP. See [02-backend-implementation.md §Pothole Photo Moderation](02-backend-implementation.md).

**No `GET /pothole-photos/{id}` in MVP.** The client does not need to poll status. Approved photos appear on the public pothole layer automatically; rejected photos are invisible to the submitter by design (see moderation policy).

## Deferred Contract Work

- `/segments/{id}` stays single-segment in MVP and Phase-2 web. If route continuity ever matters, add a dedicated adjacent-segments or corridor endpoint rather than overloading this one.
- Contributor-specific stats remain out of scope until there is a real authenticated ownership proof. Do not add `/contributors/me` opportunistically.
