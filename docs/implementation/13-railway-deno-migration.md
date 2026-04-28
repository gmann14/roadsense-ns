# 13 — Railway / Deno Migration (Path C)

*Last updated: 2026-04-28*

Covers: migrating the Edge Functions stack off Supabase onto a single Deno service running against a Railway-hosted PostGIS database. Keeps the existing `functions/` handler logic; replaces `supabase-js` with a raw Postgres client; consolidates `/functions/v1/*` routing into one entrypoint.

## Why this migration

- **Cost**: Supabase Pro is $25/mo. Self-hosted Supabase on Railway is $25-40/mo (6+ services). Path C runs at $5-10/mo (1 Postgres + 1 Deno service).
- **Architectural simplicity**: one Deno service to deploy, log, and reason about. No Kong gateway routing, no PostgREST version drift, no template updates breaking things silently.
- **Performance**: each function call drops a hop (client → Deno → Postgres vs client → Deno → PostgREST → Postgres). ~10–50ms saved per request.
- **Local dev**: still use `supabase start` for the local Postgres + the existing `supabase functions serve`. Only the prod URL changes; dev loop unchanged.

## Goals + non-goals

**Goals**
- All existing iOS endpoints (`upload-readings`, `pothole-actions`, `feedback`, `stats`, `tiles`, `tiles-coverage`, `segments`, `segments-worst`, `potholes`, `health`) reachable on Railway.
- All existing pgTAP and Deno tests still pass.
- Same JSON shapes the iOS client and web client already expect — zero client refactor required for the non-photo endpoints.
- One Dockerfile that Railway can build.

**Non-goals (this migration)**
- Photo upload (`pothole-photos`, `pothole-photo-moderation`, `pothole-photo-image`) — defer until R2 is set up. Hide the iOS photo button behind a feature flag for now.
- Realtime subscriptions — we never used them.
- Auth (signup/login flows) — we use anonymous device tokens, not user accounts.
- A new web admin UI — Supabase Studio's loss is fine.

## Target architecture

```
┌─────────────────┐     ┌──────────────────────────────────┐
│  iOS / Web      │ →   │ Railway Edge Service (Deno)     │
│                 │     │  - server.ts (router)            │
│  HTTPS to       │     │  - functions/                    │
│  edge.host      │     │    - upload-readings/handler.ts  │
│  /functions/v1  │     │    - pothole-actions/handler.ts  │
│                 │     │    - feedback/handler.ts         │
│                 │     │    - tiles/handler.ts            │
│                 │     │    - ...                         │
└─────────────────┘     └──────────────────────────────────┘
                                    │
                                    │ DATABASE_URL (private)
                                    ↓
                        ┌──────────────────────┐
                        │ Railway Postgres     │
                        │ + PostGIS 3.7        │
                        │ + pg_cron            │
                        │ + osm.* schema       │
                        └──────────────────────┘
```

Two services. Internal communication via Railway private network (`postgis.railway.internal`). Public ingress only on the Edge Service via a generated `*.up.railway.app` domain.

## File layout

```
supabase/
├── functions/
│   ├── server.ts                      # NEW: single Deno entrypoint
│   ├── db.ts                          # NEW: postgres-deno pool singleton
│   ├── deps.ts                        # NEW: pinned import map
│   ├── Dockerfile                     # NEW: Railway build target
│   ├── _shared/
│   │   ├── http.ts                    # unchanged
│   │   ├── apikey.ts                  # NEW: shared-secret apikey check
│   │   └── routes.ts                  # NEW: URLPattern matchers
│   ├── upload-readings/
│   │   ├── handler.ts                 # unchanged
│   │   ├── runtime.ts                 # MODIFIED: pg-based RPC calls
│   │   └── index_test.ts              # MODIFIED: new mock shape
│   ├── pothole-actions/               # similar pattern
│   ├── stats/                         # similar pattern
│   ├── tiles/, tiles-coverage/        # similar
│   ├── segments/, segments-worst/     # similar
│   ├── potholes/, health/             # similar
│   ├── feedback/                      # similar
│   ├── pothole-photos/                # UNTOUCHED (deferred; not deployed)
│   ├── pothole-photo-moderation/      # UNTOUCHED (deferred)
│   └── pothole-photo-image/           # UNTOUCHED (deferred)
└── migrations/                        # unchanged
```

## The DB shim

```typescript
// supabase/functions/db.ts
import postgres from "https://deno.land/x/postgresjs@v3.4.4/mod.js";

let _pool: ReturnType<typeof postgres> | null = null;

export function db() {
  if (!_pool) {
    const url = Deno.env.get("DATABASE_URL");
    if (!url) throw new Error("DATABASE_URL is not set");
    _pool = postgres(url, {
      max: 10,
      idle_timeout: 30,
      connect_timeout: 10,
      ssl: url.includes("railway.internal") ? false : "require",
    });
  }
  return _pool;
}

export type DB = ReturnType<typeof db>;
```

Singleton at module load — one pool per Deno process. Internal Railway hosts disable SSL; public connections require it.

## The router

```typescript
// supabase/functions/server.ts
import { handleUploadReadings } from "./upload-readings/handler.ts";
import { handleFeedback } from "./feedback/handler.ts";
import { handleStats } from "./stats/handler.ts";
import { handleTile } from "./tiles/handler.ts";
// ...

const ROUTES: Array<[URLPattern, (req: Request) => Promise<Response>]> = [
  [new URLPattern({ pathname: "/functions/v1/health" }), handleHealth],
  [new URLPattern({ pathname: "/functions/v1/upload-readings" }), handleUploadReadings],
  [new URLPattern({ pathname: "/functions/v1/pothole-actions" }), handlePotholeActions],
  [new URLPattern({ pathname: "/functions/v1/feedback" }), handleFeedback],
  [new URLPattern({ pathname: "/functions/v1/stats" }), handleStats],
  [new URLPattern({ pathname: "/functions/v1/tiles/:z/:x/:y.mvt" }), handleTile],
  [new URLPattern({ pathname: "/functions/v1/tiles/coverage/:z/:x/:y.mvt" }), handleCoverageTile],
  [new URLPattern({ pathname: "/functions/v1/segments/:id" }), handleSegmentDetail],
  [new URLPattern({ pathname: "/functions/v1/segments-worst" }), handleSegmentsWorst],
  [new URLPattern({ pathname: "/functions/v1/potholes" }), handlePotholes],
];

Deno.serve(async (req) => {
  const url = new URL(req.url);
  for (const [pattern, handler] of ROUTES) {
    if (pattern.test(req.url)) {
      return handler(req);
    }
  }
  return new Response("Not found", { status: 404 });
});
```

URLPattern is built into Deno. Path params (`:z`, `:x`, `:id`) are extracted in each handler via `pattern.exec(req.url)`. No router library needed.

## Auth model change

**Before** (Supabase): every request carries a JWT in `Authorization: Bearer ...`. Functions decode it to determine if the caller is anon / authenticated / service_role. Internally functions use the service-role JWT to talk to PostgREST.

**After** (Path C): a single shared secret (`PUBLIC_API_KEY`). Functions check `apikey` header matches before serving. No JWT decoding. Internal DB calls use the postgres connection — no service-role concept needed.

This is **simpler and equivalent in security** for our model:
- iOS already ships the anon key in the bundle (anyone who reverses the IPA gets it). Same with Supabase JWT.
- Real protection is per-endpoint input validation + per-IP rate limiting. Both stay.
- Server-internal calls (from one function to another) just call shared TypeScript directly — no inter-function auth needed.

## Per-call shape changes

```typescript
// Before
const { data, error } = await supabase.rpc("apply_pothole_action", { p_action_id, ... });
if (error) throw new Error(error.message);
return data;

// After
const sql = db();
const [row] = await sql`SELECT apply_pothole_action(
  ${actionId}::uuid, ${tokenHash}, ${actionType}, ${lat}, ${lng}, ...
) AS result`;
return row.result;
```

```typescript
// Before
const { data } = await supabase.from("public_stats_mv").select("*").maybeSingle();
return data;

// After
const sql = db();
const [row] = await sql`SELECT * FROM public_stats_mv LIMIT 1`;
return row ?? null;
```

```typescript
// Before
const { data } = await supabase.rpc("get_tile", { z, x, y });
return new Response(data, { headers: { "Content-Type": "application/x-protobuf" } });

// After
const sql = db();
const [row] = await sql`SELECT get_tile(${z}, ${x}, ${y}) AS bytes`;
return new Response(row.bytes, { headers: { "Content-Type": "application/x-protobuf" } });
```

postgres-deno returns `bytea` columns as `Uint8Array` — Response can accept that directly.

## Test refactor pattern

The existing tests use a `defaultDeps()` helper that returns mocked submitters / inserters. We replace `supabase` with an injectable `db` interface in handler signatures.

**Before:**
```typescript
export type FeedbackHandlerDeps = {
    checkRateLimit: (ip: string) => Promise<RateLimitResult>;
    insertFeedback: (params: ...) => Promise<FeedbackInsertResult>;
};

export function createFeedbackHandler(deps: FeedbackHandlerDeps) { ... }
```

**After:** unchanged. The `deps` pattern is already correct for testability. We just need to update the production wiring (`index.ts`) to inject pg-backed implementations instead of supabase-js-backed ones.

The handler tests don't need to change at all. Only the runtime integration changes.

## Sticking points and mitigations

These are the things most likely to bite:

### 1. JSONB round-tripping
Supabase auto-serializes JSON. postgres-deno returns JSONB as already-parsed objects via tag-template syntax, but you must use the right interpolation:
```typescript
await sql`UPDATE x SET data = ${sql.json(payload)} WHERE id = ${id}`
```
**Mitigation:** wrap any JSON binding in `sql.json(...)`. Add a test for the feedback insert path that round-trips a payload with unicode emoji + nested objects.

### 2. UUID and BYTEA types
postgres-deno passes UUIDs as strings; bytea as Uint8Array. RPCs that accept these in our migrations use `::UUID` and `::BYTEA` casts that need to be present in the call site.
**Mitigation:** standardize on explicit `::UUID` and `decode($1, 'hex')::BYTEA` casts in handler SQL. Add tests covering each.

### 3. anon role grants in migrations
Several migrations `GRANT SELECT ... TO anon` and `GRANT EXECUTE ... TO service_role`. Plain Postgres has neither role.
**Mitigation:** add a new migration `00000000000001_railway_roles.sql` that runs at the start of the chain and creates the roles as no-op stand-ins:
```sql
DO $$ BEGIN
  CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
```
Existing GRANTs become harmless. Local Supabase already has these roles, so no change there.

### 4. pg_cron availability
Railway PostGIS template runs Postgres 16. pg_cron is available as an extension but needs `CREATE EXTENSION` and may need shared_preload_libraries. If unavailable, fall back to a Railway scheduled service that hits a webhook endpoint (`/cron/refresh-public-stats-mv`).
**Mitigation:** detect `pg_cron` availability in the migration; on absence, log a warning and create a small Railway cron service. Pre-flight test: try `CREATE EXTENSION pg_cron` against the Railway DB before deploy.

### 5. Connection pool sizing for cold starts
Railway scales to zero on the free hobby tier (services get killed during long idleness). On wake, the first request creates a Postgres pool from scratch — adds ~50–100ms to the first request.
**Mitigation:** set `RAILWAY_HEALTHCHECK_PATH=/functions/v1/health`. Railway pings this every few minutes, keeping the service warm. Cold starts only happen during deploys.

### 6. Unbounded query result memory
`SELECT * FROM road_segments` would load ~1.7M rows into memory. Real handlers always have LIMITs, but a misconfigured one could OOM the Deno process.
**Mitigation:** code review check; add a regression test that asserts each handler has a `LIMIT` clause where applicable.

### 7. SSL certificate verification
Railway's public TCP proxy uses Let's Encrypt; internal `*.railway.internal` doesn't.
**Mitigation:** the `db.ts` shim already conditionalizes SSL on URL pattern. Verified by smoke test before deploy.

### 8. Migration order with Railway
Local supabase migrations run in chronological filename order. Railway is just a Postgres URL — no migrate-up tooling. We use `supabase db push --linked` pointed at Railway? No — that needs a Supabase project. We need a different runner.
**Mitigation:** add a small shell script `scripts/migrate-railway.sh` that loops through `supabase/migrations/*.sql` and `psql "$DATABASE_URL" -f $each`. Idempotency guaranteed by every migration starting with `CREATE ... IF NOT EXISTS` or `DO $$ ... EXCEPTION ...`.

### 9. JWT_SECRET drift
Old iOS builds may still have the local Supabase JWT in their bundle. Hitting the new server with that JWT would fail apikey check.
**Mitigation:** new staging xcconfig sets a fresh `RAILWAY_ANON_KEY`. Old Local Debug builds keep talking to local Supabase (unchanged). Production iOS builds (TestFlight) point at Railway.

### 10. Test environment gap
Existing Deno tests use mocked deps. They never actually exercise postgres-deno. A bug in the new `runtime.ts` wouldn't be caught by unit tests.
**Mitigation:** add new integration tests that spin up a Postgres in Docker (using `denopg-test` pattern or test against the local Supabase Postgres) and assert end-to-end behavior. Not catch-everything but catches real wiring bugs.

### 11. Photo upload regression
The iOS app's "Take photo" button currently routes through `pothole-photos` Edge Function. After migration, that function isn't deployed. The button would surface a 404.
**Mitigation:** add a feature flag `IS_PHOTO_UPLOAD_ENABLED` defaulting to `false` in the staging build. The button becomes hidden or shows "coming soon". Local Debug build keeps photos working against local Supabase.

### 12. CORS for the web client
PostgREST + Supabase send CORS headers automatically. Our new Deno service must set them too, or the web client gets blocked.
**Mitigation:** wrap every response in a `withCors(...)` helper that adds `Access-Control-Allow-Origin: *` (we have no auth cookies; * is fine) plus `Access-Control-Allow-Headers: Content-Type, apikey, Authorization`. Add a test asserting OPTIONS preflight returns 204 with correct headers.

### 13. Web client's REST fallback
`getPublicStats()` first tries `/rest/v1/public_stats_mv?select=...`, falls back to `/functions/v1/stats`. Without PostgREST, the REST URL returns 404 silently and the fallback fires.
**Mitigation:** verified by existing fallback path; no code change needed. Add a test that asserts `getPublicStats` survives a 404 on the REST URL.

## Phase breakdown (RED/GREEN)

Each phase is a self-contained PR. All previous phases stay green.

### P1 — DB shim + router scaffold

- **RED:** new `server_test.ts` asserts an unmatched URL returns 404, and a matched URL invokes a stub handler with the right path params
- **GREEN:** `db.ts`, `server.ts`, `_shared/apikey.ts`, `_shared/routes.ts` (URLPattern wrapper)
- **Acceptance:** `deno test --allow-all supabase/functions/server_test.ts` passes

### P2 — Refactor stats (simplest, no path params)

- **RED:** existing `stats/index_test.ts` updated to inject a mock pg interface; assertions unchanged
- **GREEN:** swap supabase-js for pg-deno in `stats/index.ts`
- **Acceptance:** existing `stats/index_test.ts` still passes; smoke against local Postgres returns same JSON

### P3 — Refactor RPC-based handlers

Order: `health`, `upload-readings`, `pothole-actions`, `tiles`, `tiles-coverage`, `potholes`, `feedback`. Each as its own commit; each runs the existing test file plus a new pg integration test.

### P4 — Refactor table-query handlers

Order: `segments`, `segments-worst`. Same pattern.

### P5 — apikey middleware

- **RED:** test asserts request without `apikey` header returns 401; correct apikey returns 200
- **GREEN:** `_shared/apikey.ts` middleware wrapping `server.ts` route dispatch
- **Acceptance:** all previous tests still pass when test setup includes the mock apikey

### P6 — CORS

- **RED:** test asserts OPTIONS preflight returns 204 with the documented headers
- **GREEN:** `withCors(...)` helper, applied to all responses
- **Acceptance:** web client (browser) can still call endpoints

### P7 — Migrations runner

- **RED:** `scripts/migrate-railway.sh --dry-run` lists pending migrations against local Supabase
- **GREEN:** simple `psql -f` loop with idempotency
- **Acceptance:** migrations apply cleanly to a fresh Railway Postgres

### P8 — pg_cron compatibility

- **RED:** test asserts the cron-registration migration succeeds OR logs a clear "pg_cron unavailable; cron skipped" warning
- **GREEN:** `IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron')` guard on cron-related blocks
- **Acceptance:** migration applies on Railway whether or not pg_cron is available

### P9 — Dockerfile + local build

- **RED:** `docker build` succeeds and the resulting image starts and serves `/functions/v1/health` against a local Postgres
- **GREEN:** Dockerfile in `supabase/functions/Dockerfile`
- **Acceptance:** local end-to-end via Docker passes api-smoke.sh

### P10 — Railway deploy

- **RED:** none — this is operational work
- **GREEN:** push image to Railway, set env vars (DATABASE_URL, PUBLIC_API_KEY, JWT_SECRET stays for now-as-a-token), generate domain
- **Acceptance:** api-smoke.sh against the Railway URL passes

### P11 — Run migrations + osm-import on Railway

- **GREEN:** point migrate-railway.sh + osm-import.sh at the Railway DATABASE_URL
- **Acceptance:** road_segments populated NS-wide; replay-snapshot-readings.sh successfully replays current snapshot

### P12 — iOS Staging xcconfig + photo feature flag

- **GREEN:** Config/RoadSenseNS.Staging.xcconfig set to Railway URL; FeatureFlags adds `isPhotoUploadEnabled` defaulting to false in Staging; PhotoCameraFlowView gates on it
- **Acceptance:** signed Staging IPA can drive, mark potholes, send feedback against Railway. Photo button is hidden.

### P13 — Vercel deploy of web

- **GREEN:** Vercel project linked to repo, env vars point at Railway
- **Acceptance:** /privacy-and-counts shows live counts from Railway

### P14 — Cleanup + docs

- Update scripts/README.md with the migrate-railway.sh + new local→prod parity notes
- Update 05-deployment-and-observability.md with the Railway runbook
- Mark this doc complete

## What changes for the dev loop

**Local development:** still use `supabase start`. Local Postgres + the existing `supabase functions serve` keep working. Tests still run via `deno test` against mocked deps.

**The new server.ts** is also runnable locally:
```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:54322/postgres \
PUBLIC_API_KEY=local-dev \
deno run --allow-all supabase/functions/server.ts
```

This lets you exercise the full router locally before pushing to Railway.

**Production**: a single Dockerfile that copies `supabase/functions/` into a Deno image and runs `server.ts` on `$PORT`.

## Cost model

| Item | Monthly |
|---|---|
| Railway Postgres + PostGIS (~3 GB DB, ~50% CPU) | ~$3-5 |
| Railway Edge Service (~256 MB RAM, intermittent) | ~$2-5 |
| **Total Railway** | **$5-10** |
| Vercel (web) | $0 (free tier) |
| **Grand total** | **$5-10/mo** |

vs ~$25 for Supabase Pro, ~$25-40 for self-hosted Supabase template.

## Hard stop rules

Stop and reassess if:

- A handler refactor exceeds 30 lines of net change — that means we're missing an abstraction, not just porting
- An existing test fails after refactor that we can't trace to a real semantic difference — means our mocks were lying to us, and we need integration tests before continuing
- pg_cron turns out to be a Pro-tier-only Railway feature — we'd need to redesign cron as Railway scheduled services, ~2 extra hours of work
- The Railway Postgres template is killed by Railway (templates can be deprecated) — we'd switch to Neon for DB-only and rebuild the Edge service to point there
