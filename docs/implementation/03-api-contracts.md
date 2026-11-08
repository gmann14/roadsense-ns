# 03 — API Contracts

*Last updated: 2026-11-08 (review 2026-10-18 gateway/worker fixes: worker→origin auth, edge caching, per-reading rejection, strict RFC 3339, bounded request ids, `attestation_disabled`, 503 `Retry-After`, IPv6 /64 rate-limit keys, duplicate-batch fast path)*

Authoritative request/response shapes for all endpoints. **Lock this doc by end of week 2** so iOS and backend can work in parallel without churn.

## Conventions

- Production base URL: `https://api.nsroadsense.ca/functions/v1`
- Railway origin URL: `https://api-production-075e9.up.railway.app/functions/v1`
- Local base URL: `http://127.0.0.1:54321/functions/v1`
- Content-Type: `application/json` for JSON endpoints, `application/vnd.mapbox-vector-tile` for tiles
- Auth: send the environment public API key in `Authorization: Bearer <key>` and/or `apikey: <key>` for all requests except `GET /health`, which is intentionally unauthenticated for uptime monitoring. The Cloudflare API proxy preserves this Supabase-compatible header shape. No custom auth headers — app version / OS version live in the JSON body on upload endpoints where they're relevant.
- The `ingest_reading_batch` RPC is `SECURITY DEFINER` with `EXECUTE` granted only to privileged backend roles; the public key cannot invoke it directly. Uploads MUST go through `/functions/v1/upload-readings`, which enforces validation and rate limits before dispatching.
- All timestamps are strict RFC 3339 with an explicit offset (`2026-04-17T14:30:00Z`, `2026-04-17T11:30:00.250-03:00`). The gateway rejects anything else with `validation_failed`: a missing offset, a space or lowercase `t` instead of `T`, a lowercase `z`, more than 9 fractional digits, or an impossible calendar date or time (for example `2026-02-30`, hour 24, second 60). `Date.parse`-only formats such as `2026-04-17` or `April 17, 2026` are no longer accepted.
- Request bodies are capped in bytes while streaming, whether or not `Content-Length` is sent. A body over the cap gets `413 payload_too_large`. The caps are 256 KiB for `upload-readings`, `pothole-actions` and `device-tokens`, and 16 KiB for `feedback`.
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
| `forbidden` | 403 | The request reached the Railway origin directly instead of through `api.nsroadsense.ca`, and origin auth is enforced (see "Worker → origin trust" below). |
| `not_found` | 404 | Segment/pothole/etc. doesn't exist. |
| `payload_too_large` | 413 | The request body exceeded the endpoint's byte cap. |
| `rate_limited` | 429 | Per-device or per-IP limit hit. Always carries `Retry-After`. |
| `internal_error` | 500 | An unexpected gateway error. Transient; client should retry. |
| `processing_failed` | 502 | Stored procedure errored. Transient; client should retry. |
| `upstream_unavailable` | 502 | Returned by the Cloudflare worker when it cannot reach the Railway origin. The body is JSON with CORS headers and `Cache-Control: no-store`. Transient; client should retry. |
| `service_unavailable` | 503 | Maintenance / upstream issue. |
| `attestation_disabled` | 503 | The device-token routes are switched off (`ATTESTATION_ENABLED` is not `true`). Carries `Retry-After: 21600`. |
| `photos_disabled` | 503 | The photo routes are switched off until R2 is provisioned. Carries `Retry-After: 21600`. |

**Every 503 carries a `Retry-After` header.** Gate codes (`attestation_disabled`, `photos_disabled`) use their own longer value. Every other 503 defaults to `Retry-After: 30`. Clients should honor the header the same way they do for 429.

**`x-request-id`.** Every response includes an `x-request-id` header for support and debugging, and clients log it on failure. A client may send its own `x-request-id`. The gateway keeps it only if it is 1–64 characters from `[A-Za-z0-9._:-]`, and otherwise replaces it with a fresh UUID. The value that comes back on the response is the one used in server logs and stored with feedback rows.

### Worker → origin trust

Production traffic enters through the Cloudflare worker at `api.nsroadsense.ca`, which proxies to the Railway origin.

- The worker always strips any client-supplied `x-origin-auth` and `x-client-ip`.
- It then sets `x-origin-auth: <ORIGIN_SHARED_SECRET>` and sets `x-client-ip` from Cloudflare's `cf-connecting-ip`.
- The gateway trusts `x-client-ip` for rate limiting only when `x-origin-auth` matches its own `ORIGIN_SHARED_SECRET`, using a constant-time comparison. Otherwise it falls back to the proxy-chain headers.
- When the gateway has `ORIGIN_SHARED_SECRET` set and `REQUIRE_ORIGIN_AUTH=true`, it answers `403 forbidden` to every request that lacks a valid `x-origin-auth`. `GET /health` is exempt so Railway health checks keep working. `GET /health/deep` is not exempt.
- With either variable unset (the default), the gateway behaves as before and serves direct origin requests.

**Rate-limit keys.** IPv4 clients are keyed on the full address. IPv6 clients are keyed on their /64 prefix, so rotating the interface identifier does not create a fresh bucket. IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`) are keyed as the IPv4 address.

### Edge caching (Cloudflare worker)

The worker edge-caches these public GETs. The cache key is the canonical origin URL, and responses are cached by status:

- 2xx responses are cached for the route TTL.
- 404 responses are cached for 60 s.
- Any other 4xx or 5xx response is never cached.

| Route | Edge TTL | Query params kept in the cache key |
|---|---|---|
| `/tiles/{z}/{x}/{y}.mvt`, `/tiles/coverage/{z}/{x}/{y}.mvt` | 3600 s | none |
| `/stats` | 300 s | none |
| `/segments-worst` | 300 s | `limit` (integer), `municipality` (trimmed) |
| `/top-potholes` | 300 s | `limit` (integer) |
| `/potholes` | 60 s | `bbox` (four numbers, canonicalized) |
| `/segments/{uuid}` | 60 s | none; path lowercased |

Notes on the cache key:

- Unknown query params are dropped from the key and are not forwarded to the origin.
- For tiles, `z`, `x` and `y` must be plain integers (`z ≤ 22`, `x` and `y` < 2^z). Anything else gets an edge `404 not_found` without reaching the origin.
- The tile `?v=` cache-buster is ignored at the edge. A daily `v` bump does not refresh the edge copy, which expires on its 1-hour TTL.

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

- `batch_id` must be UUIDv4, generated on client. Server uses it for idempotency — retried uploads with the same `batch_id` replay the original `{accepted, rejected, duplicate, rejected_reasons}` result. If the same device token already uploaded that `batch_id`, the gateway answers from `processed_batches` without spending upload quota, so a retry after a lost response never earns a 429. A `batch_id` that belongs to a different device still goes through the normal rate-limited path.
- Cross-batch replays of the same physical reading from the same device are also suppressed. These return 200 with `duplicate: false` for the new batch and count the suppressed row under `rejected_reasons.duplicate_reading`; this prevents manual field-test replay or local queue retry from double-counting public aggregates.
- `device_token` is a UUIDv4 generated on client, rotated monthly. It is sent over TLS to the Edge Function, hashed there with a server-side pepper, and discarded. The raw token is never persisted.
- `readings.length ≤ 1000`. Larger → `batch_too_large` error; client must split.
- Hard 400s are only for structural problems. These are:
  - missing required fields
  - non-UUID `batch_id` / `device_token`
  - non-numeric scalar fields
  - a `recorded_at` or `client_sent_at` that is not strict RFC 3339
  - `batch_too_large`
  - a batch in which too many readings are pothole-flagged (a forgery signal, so it fails the whole batch)
- Out-of-range values in a single reading never fail the batch. The gateway drops that reading and counts it in `rejected_reasons`, and the rest of the batch is ingested. These are:
  - `out_of_bounds` — `lat` outside [-90, 90] or `lng` outside [-180, 180]
  - `invalid_speed` — `speed_kmh` outside [0, 220]
  - `invalid_gps_accuracy` — `gps_accuracy_m` < 0 (iOS sends -1 for an invalid fix) or > 1000
  - `invalid_pothole_magnitude` — `pothole_magnitude` outside [0, 8] G, or `is_pothole: true` without a magnitude of at least 1.0 G
- `heading` outside [0, 360), such as the -1 that iOS sends for an invalid course, is stored as `null`. The reading is not rejected.
- Domain-level bad readings are soft-rejected and counted in `rejected_reasons` with a 200 response. That includes stale/future timestamps, out-of-bounds coordinates, low-quality readings, unpaved matches, no-match cases, and duplicate physical readings already accepted from the same device.

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
- `rejected`: `readings.length - accepted`. This includes readings the gateway dropped before ingest.
- `duplicate`: `true` if this `batch_id` was already processed (no-op retry)
- `rejected_reasons`: counts by reason code, merging gateway and SQL rejections. Only codes the server actually emits are listed — clients must tolerate unknown keys for forward-compat. Emitted codes:
  - `out_of_bounds` — lat/lng outside NS bbox (SQL) or outside world bounds (gateway)
  - `invalid_speed`, `invalid_gps_accuracy`, `invalid_pothole_magnitude` — gateway per-reading bounds (see Notes above)
  - `no_segment_match` — no road segment within the road-class-tiered radius (45m for motorway/trunk/primary/_link, 25m for secondary/tertiary/_link, 20m for everything else) and heading window
  - `low_quality` — server-visible quality gates failed (`gps_accuracy_m > 20`, `speed_kmh < 15`, `speed_kmh > 160`, or `roughness_rms` outside `[0, 15]`). Client-only gates such as `duration_s > 15` and `sample_count < 30` should have been dropped before upload and never reach the backend.
  - `future_timestamp` — `recorded_at` in the future by > 60s
  - `stale_timestamp` — `recorded_at` older than 7 days
  - `unpaved` — matched segment surface is non-paved in OSM
  - `duplicate_reading` — same device hash, same timestamp, and near-identical coordinate already exists from a prior batch

**Intentionally removed from MVP:**
- `invalid_value` — replaced by the specific per-reading gateway codes above. There is still no "accepted-but-flagged" path: a reading is either ingested or rejected.
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

### `POST /device-tokens/challenge`

Issues a one-time attestation challenge. First step of the server-issued device token exchange (B160, [17-device-attestation-and-trust.md](17-device-attestation-and-trust.md)). No request body. Rate-limited per IP using the same `check_and_bump_rate_limit` pattern as every other bucketed endpoint (30 requests / IP / hour).

**Feature gate (both device-token routes).** Real attestation verification (B161 App Attest, B163 Play Integrity) has not landed, and only a fake verifier is wired in. So both `POST /device-tokens/challenge` and `POST /device-tokens` answer `503 attestation_disabled` unless the gateway has `ATTESTATION_ENABLED=true`. The response carries `Retry-After: 21600` and `retry_after_s: 21600`. Clients must treat this as temporary: keep using their locally generated token and try again later.

```json
{
    "error": "attestation_disabled",
    "message": "Device attestation is not enabled yet.",
    "retry_after_s": 21600,
    "request_id": "01H9Z..."
}
```

**Request**

No body required.

**Response — 200 OK**

```json
{
    "challenge": "3q2-7_JZmQtAj1cQslsm7RXHQIbmQ3JcE_kJgVFbHQU",
    "expires_at": "2026-07-02T18:05:00Z"
}
```

- `challenge` is 32 random bytes, base64url-encoded (no padding).
- `expires_at` is 5 minutes from issuance. The challenge is single-use: exactly one `POST /device-tokens` redemption call may consume it, first writer wins.
- Only a salted hash of the challenge is ever persisted server-side (`token_challenges.challenge_hash`); the raw value is never written to a table or a log line.

**Response — 429 rate_limited**

```json
{
    "error": "rate_limited",
    "message": "Too many challenge requests from this IP.",
    "retry_after_s": 3600,
    "request_id": "01H9Z..."
}
```

---

### `POST /device-tokens`

Redeems a challenge plus a platform attestation payload for a server-issued device token. Second step of the B160 exchange; also the path used for the monthly token rotation (same request shape, keyed by the same `key_id`, so `attested_devices` is upserted in place rather than getting a new row — see [17-device-attestation-and-trust.md](17-device-attestation-and-trust.md) for the "no rotation history" privacy rule).

**Request**

```json
{
    "platform": "ios",
    "key_id": "NGY4ZjM5ZjItY2Q3ZC00ZmYy...",
    "attestation_object": "o2NmbXRvYXBwbGUtYXBwYXR0ZXN0Z2F0dFN0bXQ...",
    "challenge": "3q2-7_JZmQtAj1cQslsm7RXHQIbmQ3JcE_kJgVFbHQU",
    "client_app_version": "0.3.0 (12)",
    "client_os_version": "iOS 17.4.1"
}
```

**Notes**

- `platform` must be `ios` or `android`. Any other value is a `validation_failed` 400, not a distinct code — the platform enum is closed and doesn't warrant its own error family.
- `key_id` is the raw, client-generated attestation key identifier (App Attest key id / Play Integrity equivalent). The server hashes it with the same pepper used for device tokens before persisting; the raw value is never stored or logged. See `attested_devices.key_id_hash`.
- `key_id` must be base64 or base64url (`[A-Za-z0-9+/_-]`, up to two trailing `=`), at most 512 characters. `challenge` must be base64url (`[A-Za-z0-9_-]`), at most 128 characters. Anything else is `400 validation_failed`, returned before the challenge is consumed. A client that sends a malformed value can therefore retry with the same challenge.
- Redemption is rate-limited per IP: 30 requests / IP / hour, in its own bucket separate from challenge issuance. Over the limit gets `429 rate_limited` with `Retry-After`, and the challenge is not consumed.
- `attestation_object` is the platform-native attestation payload (CBOR for App Attest, an integrity token for Play Integrity), base64-encoded. **B160 does not verify this payload cryptographically** — verification is a stubbed dependency (`verifyAttestation`) that B161 (App Attest) and B163 (Play Integrity) implement for real. Until then, only a fake/test verifier is wired in.
- `challenge` is the exact value returned by `POST /device-tokens/challenge`, unmodified.
- On success, the server upserts the device's row in `attested_devices` (overwriting `public_key`, `sign_count`, `current_token_hash`, `last_rotated_at` in place — no history is kept across rotations, by design) and returns a fresh device token.

**Response — 200 OK**

```json
{
    "device_token": "a78f9e2b-4c6d-11ec-81d3-0242ac130003",
    "expires_at": "2026-08-01T18:05:00Z"
}
```

`device_token` slots into the existing `device_token` field on `/upload-readings` and `/pothole-actions` — no client-side contract change to the upload path. `expires_at` is 30 days out, matching the existing monthly rotation cadence.

**Response — 400 validation_failed**

Malformed payload, an unrecognized `platform` value (`field_errors.platform`), or a `key_id` / `challenge` outside the allowed charset or length.

**Response — 400 challenge_expired**

```json
{
    "error": "challenge_expired",
    "message": "This challenge has expired. Request a new one.",
    "request_id": "01H9Z..."
}
```

The challenge existed but its 5-minute TTL had already passed.

**Response — 400 challenge_invalid**

```json
{
    "error": "challenge_invalid",
    "message": "This challenge is missing or has already been used.",
    "request_id": "01H9Z..."
}
```

Distinct from `challenge_expired`: covers both "never issued" and "already redeemed" (a reused challenge). These collapse into one code because the underlying single-use redemption is one atomic `DELETE ... RETURNING` — by the time the row is gone, the server cannot tell "never existed" from "already consumed," and conflating them is also the safer failure mode (it doesn't confirm to a caller whether a given challenge value was ever valid).

**Response — 400 attestation_failed**

```json
{
    "error": "attestation_failed",
    "message": "Device attestation could not be verified.",
    "reason": "bad_nonce",
    "request_id": "01H9Z..."
}
```

Returned when `verifyAttestation` rejects the payload. `reason` is a short machine string from the verifier (stub-only in B160; real reasons land with B161/B163).

---

### `GET /tiles/{z}/{x}/{y}.mvt`

Vector tile with road quality overlays and pothole markers.

**Request**

- URL params: `z` (zoom), `x` (tile col), `y` (tile row)
- Optional query: `?v=<int>` for cache-busting (daily rotation). This refreshes the client's HTTP cache only, because the Cloudflare edge ignores `v` (see "Edge caching").
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
        "category": "very_rough",
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

`Cache-Control: public, max-age=60, s-maxage=60` on 200.

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

Bbox limited to ~10km × 10km; larger requests return 400. `Cache-Control: public, max-age=60, s-maxage=60` on 200.

---

### `GET /top-potholes?limit=<1-100>`

List the highest-priority active potholes for public reports and municipality pages. Railway web clients call this Deno route directly; do not use the old Supabase PostgREST RPC path.

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

Default limit is 20. Missing data is a valid empty list; malformed or out-of-range limits return 400. `Cache-Control: public, max-age=300, s-maxage=300` on 200.

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
    "data_updated_at": "2026-04-16",
    "generated_at": "2026-04-17T14:00:00Z"
}
```

- `data_updated_at` is a `YYYY-MM-DD` date, or `null`. It is the most recent day any *public* segment (≥3 contributors) received a reading. Use it for "data freshness" UI.
- `generated_at` is only the time the materialized view was last refreshed, which happens every 5 minutes. It says nothing about how fresh the data is.

Cache-Control: `public, max-age=300`. Computed from a materialized view refreshed every 5 minutes by pg_cron locally/Supabase or by the Railway Deno scheduler in hosted staging/production.

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

- `commit` comes from `RAILWAY_GIT_COMMIT_SHA`, falling back to `GIT_COMMIT_SHA` and then `GIT_SHA`.
- `version` comes from `APP_VERSION`.
- Deploy checks poll `commit` until it equals the deployed git SHA.

### `GET /health/deep`

This is the readiness check. It requires the public API key, and returns `200 {"status":"ok", ...}` or `503 {"status":"degraded", ...}`.

The response includes a `scheduler` block with one entry per job in `scheduler_job_runs`. Each entry's `status` is one of:

- `ok`
- `pending`: no success yet, but the scheduler has only just started
- `stale`: the last success is older than the job's allowed interval
- `failing`: 3 or more consecutive failures

The endpoint returns 503 when any job is `stale` or `failing`, or when the run table can't be read. The scheduled uptime workflow alerts on that 503.

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

### `GET /segments-worst?municipality=<name>&limit=<n>`

Top-N roughest published segments for the web `Worst Roads` report. The gateway route is `/functions/v1/segments-worst`. Older drafts of this doc wrote it as `/segments/worst`, which is not mounted.

**Request**

- `municipality` optional exact municipality display name, checked against the known municipalities. The gateway caches that allowlist in-process for 10 minutes, so a newly imported municipality can take up to 10 minutes to become valid.
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

`Cache-Control: public, max-age=300, s-maxage=300` on 200. This was 900 s before 2026-11-08 and now matches the 5-minute edge TTL.

**Response — 400 validation_failed**

- invalid municipality name
- invalid or missing `limit`

## Client-side Behavior Expectations

### Upload Retry

- Network error or 5xx: exponential backoff 1s, 2s, 4s, 8s, 16s, max 5 attempts. When a 503 carries `Retry-After` (every gateway 503 does), wait at least that long.
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
    "recorded_at": "2026-04-21T18:22:00Z",
    "sensor_backed_magnitude_g": 2.7,
    "sensor_backed_at": "2026-04-21T18:21:58Z"
}
```

**Notes**

- `action_id` is the idempotency key. Repeating the exact same action returns the same canonical result.
- `action_type` values: `manual_report`, `confirm_present`, `confirm_fixed`.
- `pothole_report_id` is required for `confirm_present` and `confirm_fixed`, omitted for `manual_report`.
- `lat` / `lng` are the precise client coordinates after privacy-zone filtering. Do not randomize them.
- `sensor_backed_magnitude_g` and `sensor_backed_at` are optional and valid only for `manual_report`; provide both or neither. They represent a local accelerometer pothole candidate matched to the explicit tap and are omitted for follow-up actions.
- `recorded_at` and `sensor_backed_at` must be strict RFC 3339, no more than 5 minutes in the future, and no more than 30 days old. Outside that window gets `400 validation_failed`.
- `accuracy_m` must be within [0, 500]. Outside that range gets `400 validation_failed`.
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

`status` is the canonical pothole status after the action is applied. Since B165 (corroboration gating, [17-device-attestation-and-trust.md](17-device-attestation-and-trust.md)), a `manual_report` that does not corroborate an existing report from a *different* device returns `candidate` — a non-public holding state invisible on tiles, bbox listings, and top-potholes until a second distinct device reports within 15 m / 90 days. `manual_report` and `confirm_present` return `active` once that two-device threshold is met (or when the target was already active); `confirm_fixed` may return either `active` or `resolved` depending on quorum. Clients should treat `status` as an open string set (`candidate`, `active`, `resolved`, `expired`).

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

**Current production state (2026-06-12): disabled pending R2.** The Railway gateway mounts this route (plus `pothole-photo-moderation` and `pothole-photo-image`) but answers every request with `503` and the stable error code `photos_disabled` until the R2 bucket is provisioned and the handlers are ported off Supabase Storage (see `supabase/functions/_shared/photoUploads.ts`, backlog B130):

```json
{
    "error": "photos_disabled",
    "message": "Photo uploads are temporarily disabled.",
    "endpoint": "pothole-photos",
    "retry_after_s": 21600,
    "request_id": "01H9Z..."
}
```

The response carries `Retry-After: 21600`. Clients must treat `photos_disabled` as a temporary, non-permanent condition: keep the photo queued, honor the pause, and never count it toward a permanent-failure path. The contract below describes the behavior once the flow is enabled.

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
