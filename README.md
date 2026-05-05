# RoadSense NS

An iOS app that passively collects road quality data using your phone's accelerometer while you drive. Aggregates data into a public heat map showing road roughness scores and pothole locations.

**Status:** Active implementation. The iOS app, Railway-hosted backend, and live Cloudflare web explorer are now in repo.

Start here:

- [docs/product-spec.md](docs/product-spec.md) — product scope and goals
- [docs/implementation/README.md](docs/implementation/README.md) — implementation spec index
- [docs/implementation/08-implementation-backlog.md](docs/implementation/08-implementation-backlog.md) — literal task order and acceptance criteria

Current repo structure:

- `ios/` — Xcode project, Swift app target, simulator harness, and tests
- `supabase/` — Supabase-compatible migrations, Deno function handlers, and DB tests; production runs on Railway Postgres/API
- `apps/web/` — Next.js public dashboard deployed to Cloudflare with OpenNext
- `cloudflare/` — Workers used for API/tile proxying in front of the Railway API
- `scripts/` — import, smoke, and operational scripts
- `.github/workflows/` — manual CI workflows
