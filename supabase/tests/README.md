# Backend Tests

Backend tests will live here.

Planned test layers:

- `pgTAP` for SQL and schema behavior
- Deno tests for Edge Function contracts

See [04-testing-and-quality.md](../../docs/implementation/04-testing-and-quality.md) for the expected coverage.

Current pgTAP suites:

- `001_schema.sql` — extensions, core tables, indexes, and basic RLS/read permissions
- `002_road_segment_refresh.sql` — `road_segments_staging` merge semantics and execute permissions
- `003_osm_segmentization.sql` — fixture-driven segmentization plus municipality/feature tagging via the DB functions that back the operational SQL scripts
- `004_rematch_readings_after_refresh.sql` — refresh rematch behavior for reassignment, stale-nulling, `p_since`, and execute permissions
- `005_ingest_reading_batch.sql` — happy path, soft-rejection accounting, duplicate replay, malformed payload failure, aggregate folding, and execute permissions
- `006_aggregate_and_pothole_folding.sql` — weighted average math, confidence/category thresholds, and pothole confirmation/new-cluster behavior
- `007_nightly_recompute_and_expiry.sql` — nightly recompute math, contributor caps, expiry idempotence, and cron registration checks
