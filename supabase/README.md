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

Local verification:

- `supabase start`
- `supabase db reset`
- `supabase test db`

The OSM import scripts are designed for a manual worker or self-hosted runner, not the normal request path. They also depend on external reference geography (`ref.municipalities`) that must be loaded separately before the first import.
