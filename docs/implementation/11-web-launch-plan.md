# 11 — Web Launch Plan

*Created: 2026-05-04*
*Updated: 2026-05-05*
*Goal: keep nsroadsense.ca live as a public read-only map with low operational cost.*

This doc covers **getting and keeping the webpage live**. Product scope is in [07-web-dashboard-implementation.md](./07-web-dashboard-implementation.md). This is the infra + sequencing companion.

## Current Live Stack

The actual beta stack is:

- Web: `apps/web` as Next.js 16 deployed to Cloudflare Workers through OpenNext (`apps/web/wrangler.jsonc`)
- API public base: `https://api.nsroadsense.ca/functions/v1`
- API proxy: `cloudflare/api-proxy`, which forwards to the Railway API origin and preserves the Supabase-compatible anon-key headers
- DB: Railway Postgres/PostGIS
- Backend source layout: `supabase/migrations` and `supabase/functions`, still used by local Supabase CLI and tests
- Production deploy: GitHub Actions pushes migrations with `supabase db push --db-url "$DATABASE_URL"` and triggers Railway through `RAILWAY_DEPLOY_HOOK_URL`

The earlier pre-baked R2 tile plan below is now a cost/performance option, not the current production path. Current web traffic fetches live API/tile data through the Cloudflare API proxy.

## TL;DR

Current production uses Cloudflare in front of both the web app and the Railway API. Public read traffic reaches Railway through `api.nsroadsense.ca` until we choose to move tiles to a pre-baked R2 path.

```
Public users
   │
   ▼
Cloudflare Worker (OpenNext, apps/web/)
   ▼
api.nsroadsense.ca / tiles.nsroadsense.ca
   │
   ▼
Cloudflare API proxy ──▶ Railway API ──▶ Railway Postgres/PostGIS

iOS app ───────────────▶ api.nsroadsense.ca ─────┘
```

## Non-goals (defer until v2)

- Sub-minute tile freshness (24h is fine — confirmed)
- User accounts, contribution history, personal dashboards
- Per-municipality auth or admin tooling
- Export endpoints, custom report builders
- Server-rendered map (we're using Mapbox GL JS in the browser)

## Hosting choice: Railway now, Hetzner when economics demand

Three viable shapes were considered for the origin (the public web layer is Cloudflare regardless). We're going with Railway for the launch, with a documented migration path to Hetzner when the side-project portfolio grows. Pricing below is current as of 2026-05-04.

### Option A — Railway (chosen for launch)

| Plan | Base | Resource limits | What you get |
|---|---|---|---|
| Free | $0/mo for 30-day trial ($5 credit), **$1/mo after** | 1 project, 3 services per project, 1 vCPU / 0.5GB RAM per service, 0.5GB volume | Tight — barely fits Postgres + API + cron, no headroom |
| **Hobby** | **$5/mo minimum, includes $5 credit** | 50 projects, 50 services/project, up to 48 vCPU / 48GB RAM, 5GB volume | Sweet spot for solo dev with multiple projects |
| Pro | $20/mo minimum, includes $20 credit | 100 projects, up to 1,000 vCPU / 1TB RAM, 1TB volume | Overkill for side projects |

Resource metering on Hobby/Pro:

- Memory: $0.00000386 / GB-sec (≈ $10/mo per GB always-on)
- CPU: $0.00000772 / vCPU-sec (≈ $20/mo per always-on vCPU)
- Volume storage: $0.00000006 / GB-sec (≈ $0.16/mo per GB)
- Egress: $0.05 / GB (after free tier)
- Object storage: $0.015 / GB-month

For RoadSense (small Postgres + API + nightly cron, mostly idle): expected actual usage **$3–7/mo**, fully covered by the $5 included Hobby credit.

- **Net cost**: $0–2/mo for this project alone
- **Ops burden**: near zero — managed Postgres, TLS, GitHub-deploys, secrets UI
- **Time to live**: hours (we already have Railway CLI authed)
- **Constraint**: cost scales roughly linearly with project count beyond a couple

### Option B — Hetzner Cloud (deferred)

Current pricing (USD, as of 2026-05-04):

| Tier | RAM / vCPU / SSD | Price | Use case |
|---|---|---|---|
| Cost Optimized (CX, shared) | varies | from **$5.59/mo** | dev/test, low CPU |
| **Regular Performance (CPX, shared)** | **e.g. CPX21: 4GB / 3 vCPU / 80GB** | **from $7.09/mo** | **best price/perf, 3–5 projects** |
| General Purpose (dedicated) | dedicated vCPU | from $19.09/mo | high-traffic, paid services |

For a side-project stack: **CPX21 at ~$7.09/mo** is the target. Hosts 3–5 small projects comfortably; CPX31 ($~12) hosts 5–10.

- **Cost**: ~$7/mo flat regardless of project count
- **Ops burden**: real but manageable — Postgres + PostGIS once, Caddy for TLS, daily `pg_dumpall` to R2, one box to patch
- **Pattern**: one Postgres cluster with many databases, Caddy reverse-proxying many domains, optional Coolify for git-push-to-deploy
- **Time to live for the first project**: 1–2 days of upfront setup before shipping

### Option C — Digital Ocean (considered, rejected)

| Service | Price | Notes |
|---|---|---|
| Droplet (Basic, 1GB) | $6/mo | 1 vCPU, 25GB SSD — tight for multi-project |
| Droplet (Basic, 4GB) | ~$24/mo | 2 vCPU, 80GB — apples-to-apples vs CPX21 |
| Managed Postgres | $15/mo minimum | 1GB RAM, 10GB SSD — expensive vs Railway metered |
| App Platform (paid) | from $5/mo | 1 vCPU, 512MiB, 50GiB transfer |
| Spaces (S3-compatible) | $5/mo | 250GB included; Cloudflare R2 is cheaper |
| Daily backups | +30% of droplet cost | vs. roll-your-own to R2 |

Verdict: **DO is roughly 3× more expensive than Hetzner for equivalent specs** (4GB RAM is $24 vs $7). Nicer UX, better support, more US/Canada regions, but pure cost/perf goes to Hetzner. App Platform is competitive with Railway at the small end but caps lower. **Skip DO** for this project unless we need a managed control plane and US-East latency that Hetzner can't match.

### Side-by-side at our scale

| | Railway Hobby | Hetzner CPX21 | DO Droplet (4GB) |
|---|---|---|---|
| 1 project (RoadSense only) | **$0–2/mo** | $7/mo | $24/mo |
| 3 projects | $9–21/mo | **$7/mo** | $24/mo (one box) or 3× $6 = $18 small |
| 5 projects | $15–35/mo | **$7/mo** until you upsize | $24+/mo |
| Backups + TLS | included | DIY (free with Caddy + restic) | +30% cost |
| Ops time per project | ~minutes | ~hours upfront, then minutes | ~minutes |

Crossover: Railway → Hetzner when running **3–4 active projects** simultaneously, or when monthly Railway bill consistently exceeds Hetzner's flat rate.

### Why Railway now

1. We already have a Railway service running for RoadSense ingest. Building on it is faster than a parallel Hetzner setup.
2. Launch is on the critical path; spending 1–2 days on Hetzner ops before shipping doesn't move the project forward.
3. At one project, Railway is dramatically cheaper than DO and within ~$5/mo of Hetzner — the ops time saved is worth more than the price difference.

### Migration trigger to Hetzner

Switch to Hetzner CPX21 (or CPX31) when **either**:

- Total Railway spend across all active side projects exceeds **$15/month for two consecutive months**, OR
- We start a **fourth active side project** (the point where Hetzner's flat fee wins decisively)

### What changes if we migrate to Hetzner

Plan stages are nearly identical; only the **execution layer for Postgres + cron + ingest API** changes. The web layer (Cloudflare Pages + R2) is identical because Cloudflare doesn't care what the upstream is.

| Plan stage | Railway version | Hetzner version |
|---|---|---|
| Postgres host | Railway-managed Postgres | Postgres 16 + PostGIS on the box |
| Tile bake job | Railway cron service | systemd timer on the box |
| Ingest API | Railway service from GitHub | systemd unit deployed via `git pull && systemctl restart` (or Coolify for git-push-to-deploy) |
| Backups | Railway-managed | Nightly `pg_dumpall` + restic to R2 |
| TLS for `api.roadsense.ca` | Railway provides | Caddy auto-TLS (free Let's Encrypt) |

Migration steps when triggered:

1. Spin up Hetzner CPX21, install Postgres + PostGIS + Caddy (or Coolify)
2. `pg_dump` from Railway → restore on Hetzner
3. Update DNS: `api.roadsense.ca` from Railway CNAME → A record pointing at Hetzner IP
4. Verify ingest works, decommission Railway services
5. Tile bake cron rewritten as systemd timer

Estimated migration time: **half a day to one day** of focused work, done once.

### Why this hybrid (Railway/Hetzner compute + Cloudflare static + R2) holds up either way

The architectural commitment is **public traffic never touches the origin** — it hits Cloudflare CDN serving pre-baked tiles from R2. That decision is independent of Railway-vs-Hetzner. The origin (whatever it is) only does ingest + nightly bake, which is small, predictable, and easy to migrate. So picking Railway today doesn't lock us in; the data layer is portable, and Cloudflare absorbs scale regardless of where the origin runs.

## Stage 0 — Prerequisites (~30 min)

| Item | Status | Notes |
|---|---|---|
| `roadsense.ca` registered | ✅ | Webnames.ca, ACTIVE |
| Railway CLI authed | ✅ | `graham.mann14@gmail.com` |
| Cloudflare account | ❓ | Verify exists; sign up if not |
| `wrangler` CLI installed | ❌ | `npm i -g wrangler && wrangler login` |
| Mapbox public token | ✅ | `pk.eyJ1IjoiZ21hbm4xNCIs...` (in iOS xcconfig) |
| `apps/web/` builds locally | ❓ | `cd apps/web && npm install && npm run build` to confirm |

**DNS strategy**: keep registration at Webnames.ca; change nameservers to Cloudflare. Faster than a transfer (hours vs days), free, can transfer later if desired.

## Stage 1 — Cloudflare bootstrap (~1h)

1. Sign up / log in to Cloudflare
2. Add `roadsense.ca` to Cloudflare → choose Free plan → Cloudflare gives you 2 nameservers
3. Log in to Webnames.ca → change nameservers to the Cloudflare ones
4. Wait for DNS propagation (15 min – 24h, usually fast)
5. In Cloudflare → R2 → create two buckets:
   - `roadsense-tiles` (public read, custom domain `tiles.roadsense.ca`)
   - `roadsense-photos` (public read, custom domain `photos.roadsense.ca`)
6. Generate R2 API token with read/write to both buckets — save Access Key ID + Secret Access Key for Railway env

**Subdomains**: `tiles.roadsense.ca` and `photos.roadsense.ca` use Cloudflare's R2 → custom domain feature (no CNAME needed; Cloudflare handles it natively via the R2 dashboard).

## Deferred Option — Tile bake job on Railway/R2 (~1 day)

A new Railway service that runs nightly. Reads from existing Postgres, writes to R2.

### Service: `roadsense-tile-baker`

- **Runtime**: Node.js or Go. Recommend Go for speed (tile bake is the slow path).
- **Schedule**: Railway cron, `0 7 * * *` UTC = 03:00 Atlantic (DST-aware? Use UTC; consistent year-round).
- **Resource**: Railway scale-to-zero. Runs ~10–30 min per night, costs ~$0.50/month.

### What it does

```pseudocode
date = today UTC, ISO yyyy-mm-dd
for z in 8..14:
  for (x, y) in tiles_covering(NS_BBOX, z):
    mvt = postgres.query("SELECT ST_AsMVT(...) FROM segment_aggregates WHERE ...")
    if mvt.is_empty: continue   # don't waste bytes on ocean/forest tiles
    r2.put(
      bucket = "roadsense-tiles",
      key = f"v/{date}/{z}/{x}/{y}.mvt",
      body = mvt,
      content_type = "application/vnd.mapbox-vector-tile",
      cache_control = "public, max-age=31536000, immutable"
    )

r2.put(
  bucket = "roadsense-tiles",
  key = "current.json",
  body = {"version": date},
  cache_control = "public, max-age=300"   # 5 min so reload picks up new bake
)
```

### Tile counts and sizes

NS bbox ≈ 43.4°N–47.0°N, 66.6°W–60.6°W. After skipping empty tiles:

| Zoom | Tiles to bake (rough) | Use case |
|---|---|---|
| z=8 | ~6 | provincial overview |
| z=10 | ~50 | regional |
| z=12 | ~600 | city / town |
| z=14 | ~5,000 | street level |

**~6,000 non-empty tiles total**, ~5KB each → ~30MB upload per night. Storage cost: $0.015/GB/month → **<$0.01/month**. Egress is free out of Cloudflare. R2 PUT operations: 6,000/night × 30 = 180k/month — well under R2's 1M-free Class A request tier.

Daily storage growth (one snapshot per day, 30 retained): ~900MB. Pruning: cron deletes versions older than 30 days, keeps weekly snapshots for 6 months.

### Postgres requirements (likely already in place)

- PostGIS extension
- `segment_aggregates` table (or materialized view) with road geometry + roughness score + pothole counts
- `pothole_actions` table for marker layer
- Indexes: GIST on geometry columns, btree on date columns

**If aggregates aren't computed yet**: add a step before tile bake — refresh materialized view or recompute incremental aggregates. Already designed in [02-backend-implementation.md](./02-backend-implementation.md).

### Secrets needed in Railway service

- `DATABASE_URL` — internal Railway link to Postgres
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
- `R2_TILES_BUCKET=roadsense-tiles`
- `BAKE_BBOX=43.4,-66.6,47.0,-60.6` (S, W, N, E)
- `BAKE_ZOOMS=8-14`

## Stage 3 — Web app on Cloudflare Workers/OpenNext (~½ day)

`apps/web/` is a Next.js 16 project deployed to Cloudflare Workers with OpenNext.

### Deploy to Cloudflare

1. Build locally or in CI:
   - `cd apps/web`
   - `npm ci`
   - `npm run build:cloudflare`
2. Deploy:
   - `npm run deploy:cloudflare`
3. Routes live in `apps/web/wrangler.jsonc`:
   - `nsroadsense.ca/*`
   - `www.nsroadsense.ca/*`
4. Set env vars in `wrangler.jsonc` or Cloudflare dashboard:
   - `NEXT_PUBLIC_MAPBOX_TOKEN` (from xcconfig)
   - `NEXT_PUBLIC_API_BASE_URL=https://api.nsroadsense.ca/functions/v1`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`

### App changes

- `apps/web/lib/api/client.ts`: API/tile URL templates point at `NEXT_PUBLIC_API_BASE_URL`
- Mapbox style: vector sources point at `https://api.nsroadsense.ca/functions/v1/tiles/...` and coverage equivalents
- Pages: index (map), `/methodology`, `/privacy`, `/municipality/[slug]`, `/reports` — already scaffolded

### Note on Next.js on Pages

This repo uses `@opennextjs/cloudflare`, not Vercel or `@cloudflare/next-on-pages`.

## Stage 4 — DNS cutover (~1h)

Once Pages and R2 are working with their default domains:

| Subdomain | Points to | Type |
|---|---|---|
| `nsroadsense.ca` | Cloudflare web Worker | Worker route |
| `www.nsroadsense.ca` | Cloudflare web Worker / redirect | Worker route |
| `api.nsroadsense.ca` | Cloudflare API proxy Worker | Worker route |
| `tiles.nsroadsense.ca` | Cloudflare API proxy Worker | Worker route |

Update iOS `Staging.xcconfig` and `Production.xcconfig`:
```
API_BASE_URL = https://api.nsroadsense.ca
```

Push xcconfig change → next TestFlight build picks it up.

## Stage 5 — Operations (~½ day, ongoing)

### Monitoring

- **Cloudflare Analytics**: free, gives requests/bandwidth per domain
- **Railway**: built-in logs + metrics for the cron + API services
- **Postgres slow query log**: enable on Railway Postgres
- **Sentry** (deferred): wire up before public launch announcement, not required for soft launch

### Cache invalidation

Tiles are immutable per-day, so they never need invalidation — `current.json` is the only mutable file. Its 5-min TTL is the worst-case staleness for a deployed page after bake completes. Acceptable.

### Daily checklist for the first 2 weeks

- Did last night's bake succeed? (Railway log alert if cron failed)
- Did `current.json` update? (`curl https://tiles.roadsense.ca/current.json`)
- Any 5xx spikes in Cloudflare Analytics?
- Any failed iOS uploads? (Railway API log)
- R2 storage trending up as expected (~30MB/day growth, <1GB after 30 days)?

After 2 weeks, switch to weekly review.

### Rollback plans

| Failure | Recovery |
|---|---|
| Bake job fails | Web keeps serving yesterday's tiles via `current.json`; manual cron retry |
| Bad data in last bake | Edit `current.json` to point at previous date; re-bake when fixed |
| Cloudflare Pages outage | Static fallback page (we deploy a one-page `static.roadsense.ca` for this) |
| Railway outage | Public web unaffected; iOS uploads queue locally (already handled in `ReadingStore.swift`) |
| R2 outage | Public web hard down; rare, no SLA, accept the risk for free tier |

### Cost projection (steady state)

| Line item | Monthly |
|---|---|
| Railway Hobby plan + included credit | $0–2 |
| R2 storage (~1GB total over 30-day retention) | <$0.02 |
| R2 Class A operations (writes) | $0 (under 1M free) |
| R2 Class B operations (reads) | $0 (Cloudflare Pages → R2 is free egress; CDN absorbs end-user reads) |
| Cloudflare Pages | $0 |
| Cloudflare DNS | $0 |
| Domain renewal (annualized) | ~$1.20 (.ca @ ~$15/yr) |
| **Total** | **~$2/month** |

If the site goes viral and we serve 100k+ users/month: still ~$2/month, because Cloudflare CDN is free and R2 egress through Cloudflare is free. The costs stay flat with scale until raw R2 storage exceeds 10GB or Railway compute scales up — neither is realistic for this use case.

## Sequencing summary

| Stage | Time | Blocks on |
|---|---|---|
| 0. Prerequisites | 30 min | — |
| 1. Cloudflare bootstrap + DNS | 1h | Stage 0 |
| 2. Tile bake service | ~1 day | Stage 1 |
| 3. Web app on Pages | ~½ day | Stages 1, 2 |
| 4. DNS cutover | 1h | Stage 3 working on default URL |
| 5. Operational monitoring | ~½ day | Stage 4 |

**Total: 2.5–3 working days** from "yes go" to "roadsense.ca live with daily-updated map".

## Open questions

1. **Mapbox style**: do we use a Mapbox-Studio-hosted style with our R2 source layered on top, or fully self-hosted style JSON? Hosted is simpler. Recommend hosted for v1.
2. **Initial dataset**: how much real data do we have to render? If <1k segments scored, the map will look empty. Worth seeding the bake from the calibration drive data first.
3. **Privacy zone bake-out**: confirm the segment aggregates query already excludes private-zone-flagged readings (it should, per `ReadingStore.swift`, but worth a unit test on the bake side).
4. **`apps/web/.vercel/` removal**: keep both providers configured during transition, or delete Vercel link before Cloudflare Pages goes live? Recommend deleting after Cloudflare is verified to avoid confusion.
5. **Sentry**: in scope for launch, or defer? Recommend defer — soft launch first, add Sentry once we have real traffic and crashes.
