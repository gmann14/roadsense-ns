# 03 — API Contracts

*Last updated: 2026-04-17*

Authoritative request/response shapes for all endpoints. **Lock this doc by end of week 2** so iOS and backend can work in parallel without churn.

## Conventions

- Base URL: `https://<project-ref>.supabase.co/functions/v1`
- Content-Type: `application/json` for JSON endpoints, `application/vnd.mapbox-vector-tile` for tiles
- Auth: Supabase anon key in `Authorization: Bearer <anon>` header for all requests (reads and uploads). Supabase Edge Functions require the Authorization header; the `apikey` header is also accepted for compatibility. No custom auth headers — app version / OS version live in the JSON body on upload endpoints where they're relevant.
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

- `batch_id` must be UUIDv4, generated on client. Server uses it for idempotency — retried uploads with the same `batch_id` return the original result.
- `device_token` is a UUIDv4 generated on client, rotated monthly. Server hashes it server-side with a pepper; raw token is never stored.
- `readings.length ≤ 1000`. Larger → `batch_too_large` error; client must split.
- `readings[].recorded_at` must be within the last 7 days.
- All `readings[].lat`/`lng` must be within NS bbox: `[-66.5, 43.3, -59.5, 47.1]`. Out-of-bounds readings are dropped server-side (not a full-batch reject).

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
  - `out_of_bounds` — lat/lng outside NS bbox (emitted by Edge Function pre-filter)
  - `no_segment_match` — no road segment within 25m / heading window (emitted by stored proc)
  - `low_quality` — GPS accuracy, speed, or window length outside acceptance envelope (emitted by Edge Function pre-filter)
  - `future_timestamp` — `recorded_at` in the future > 60s clock skew (Edge Function)
  - `stale_timestamp` — `recorded_at` older than 7 days (Edge Function)
  - `unpaved` — segment flagged as non-paved in OSM (stored proc)

**Intentionally removed from MVP:**
- `invalid_value` — a full-batch `validation_failed` is returned instead; there is no per-reading "accepted-but-flagged" path.
- `privacy_zone` — privacy zones live only on-device. Server has no knowledge of any user's zones and so cannot emit this code. Defense-in-depth here would require a separate mechanism (e.g., client attestation of a canonical public-zone list) and is deferred.

**Response — 400 validation_failed**

```json
{
    "error": "validation_failed",
    "message": "Multiple readings have speed_kmh out of range.",
    "field_errors": {
        "readings[3].speed_kmh": "must be between 0 and 200",
        "readings[12].recorded_at": "must be within the last 7 days"
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

**Response — 204 No Content** if tile has no data at this zoom.

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

Cache-Control: `public, max-age=300`. Computed from a materialized view refreshed every 5 minutes.

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
- Server never sees cleartext token — only the SHA-256 hash

## Deferred Endpoints (post-MVP)

These are in the spec but not in MVP. Listing them here so the shape is ready when needed:

- `GET /segments/worst?municipality=<name>&limit=N` — top-N worst segments
- `GET /segments/export?bbox=...&format=geojson|kml` — data export
- `POST /report-repair` — user-reported road repair
- `GET /coverage?municipality=<name>` — coverage % by municipality
- `GET /contributors/me` — personal stats authenticated via device token (requires token-signing flow, out of scope for MVP)

## Open Questions

- **[OPEN] Should `/segments/{id}` include surrounding segments for route continuity?** Current design returns `neighbors.prev/next`. For MVP, adequate. Full route requires a different endpoint.
- **[OPEN] Auth for contributor stats.** If we add personal stats at launch, we need a way to prove device ownership without accounts. Option: challenge/sign the device-token with a one-time code shown on device; out of scope for MVP.
