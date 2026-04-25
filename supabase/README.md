# Supabase Scaffold

This directory will hold the backend implementation:

- `migrations/` — Postgres schema migrations
- `functions/` — Supabase Edge Functions
- `tests/` — pgTAP and Deno tests

Implementation order starts with schema work in `B010` from [docs/implementation/08-implementation-backlog.md](../docs/implementation/08-implementation-backlog.md).

Implemented so far:

- `B010` initial schema migrations and pgTAP coverage
- `B011` staging-table refresh path plus fixture-tested OSM segmentization/tagging scripts
- `B012` reading rematch path for OSM refreshes, including fixture coverage for reassignment, stale nulling, and `p_since` filtering
- `B013` batch ingestion RPC with duplicate replay, rejection accounting, and minimal aggregate-fold plumbing
- `B014` tested incremental aggregate folding and real pothole folding behavior
- `B015` nightly recompute, pothole expiry, partition maintenance helpers, and cron registration
- `B020` quality tile RPC plus the first production Edge Function (`tiles`) with pgTAP and Deno contract coverage
- `B021` read-side stats/health models plus `segments`, `potholes`, `stats`, and `health` Edge Functions
- `B022` upload Edge Function validation, hashing, and rate limiting around the existing ingestion RPC
- `B080` coverage-tile backend (`get_coverage_tile` + `tiles-coverage`) for the future public web Coverage mode
- `B081` worst-roads backend (`public_worst_segments_mv` + `segments-worst`) for the future public report surface

Local verification:

- `./scripts/local-backend-up.sh`
- `supabase db reset`
- `supabase test db`
- `deno test -A supabase/functions/*/*_test.ts`
- `SUPABASE_ANON_KEY=... FUNCTIONS_BASE_URL=http://127.0.0.1:54321/functions/v1 ./scripts/api-smoke.sh`
- `DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres SUPABASE_ANON_KEY=... FUNCTIONS_BASE_URL=http://127.0.0.1:54321/functions/v1 ./scripts/seeded-e2e-smoke.sh`

Use `./scripts/local-backend-up.sh` for normal local development rather than raw `supabase start`. It repairs the common failure mode where Kong is up but `supabase_edge_runtime_*` has exited, which otherwise surfaces as `503 {"message":"name resolution failed"}` from Edge Function routes.

For local Edge Function secrets such as `TOKEN_PEPPER`, use `supabase/functions/.env` during development. The local edge runtime reliably picks that file up; shell-exporting secrets before `supabase start` is not enough on this machine.

The OSM import scripts are designed for a manual worker or self-hosted runner, not the normal request path. They also depend on external reference geography (`ref.municipalities`) that must be loaded separately before the first import.

The import path is now parameterized for any single Canadian province or territory via `REGION_KEY` plus `./scripts/load-municipalities.sh` and `./scripts/osm-import.sh`. It is not yet a true all-Canada deployment path, because public municipality surfaces are still keyed by display name alone and the app/backend runtime still contains Nova Scotia-specific bounds and copy.
