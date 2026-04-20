# RoadSense NS

An iOS app that passively collects road quality data using your phone's accelerometer while you drive. Aggregates data into a public heat map showing road roughness scores and pothole locations.

**Status:** Active implementation. The iOS app, Supabase backend, and the first live web explorer slices are now in repo.

Start here:

- [docs/product-spec.md](docs/product-spec.md) — product scope and goals
- [docs/implementation/README.md](docs/implementation/README.md) — implementation spec index
- [docs/implementation/08-implementation-backlog.md](docs/implementation/08-implementation-backlog.md) — literal task order and acceptance criteria

Current repo structure:

- `ios/` — Xcode project, Swift app target, simulator harness, and tests
- `supabase/` — migrations, Edge Functions, and DB tests
- `apps/web/` — Next.js public dashboard with live quality-map and segment-drawer groundwork
- `scripts/` — import, smoke, and operational scripts
- `.github/workflows/` — manual CI workflows
