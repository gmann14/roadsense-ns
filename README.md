# RoadSense NS

An iOS app that passively collects road quality data using your phone's accelerometer while you drive. Aggregates data into a public heat map showing road roughness scores and pothole locations.

**Status:** Early implementation scaffolding. The implementation specs and backlog are in place; app/backend code is just starting.

Start here:

- [docs/product-spec.md](docs/product-spec.md) — product scope and goals
- [docs/implementation/README.md](docs/implementation/README.md) — implementation spec index
- [docs/implementation/08-implementation-backlog.md](docs/implementation/08-implementation-backlog.md) — literal task order and acceptance criteria

Current repo structure:

- `ios/` — future Xcode project and Swift source
- `supabase/` — future migrations, Edge Functions, and DB tests
- `scripts/` — future import and operational scripts
- `.github/workflows/` — CI skeleton
