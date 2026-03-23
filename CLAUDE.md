# RoadSense NS

iOS app that passively collects road quality data via accelerometer while driving, aggregating into a public heat map.

## Project Status
- **Phase:** Pre-development (spec complete)
- **Spec:** [docs/product-spec.md](docs/product-spec.md)
- **Research:** [docs/research-supplement.md](docs/research-supplement.md)

## Tech Stack
- **iOS:** Swift, SwiftUI, Core Motion, Core Location, Mapbox Maps SDK, SwiftData
- **Backend:** Supabase (PostgreSQL + PostGIS), Edge Functions, stored procedures
- **Map Tiles:** Mapbox Vector Tiles via ST_AsMVT
- **Web Dashboard (future):** Next.js + Mapbox GL JS + Vercel

## Key Architecture Decisions
- Client uploads POINT readings; server assigns to road segments (server owns road network)
- Spatial operations run in PostgreSQL stored procedures, NOT Edge Functions
- Vector tiles for map rendering (not GeoJSON) — critical for performance at scale
- Privacy zones processed on-device; server never sees readings near home/work
- Readings table partitioned by month from day one
- Aggregates computed incrementally + nightly batch recompute
