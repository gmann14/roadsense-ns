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
- `008_get_tile.sql` — MVT tile function existence, the k >= 3 contributor floor (low *confidence* stays visible), zoom rules (empty below z6, arterials only below z12), and execute permissions
- `009_public_read_models.sql` — stats MV, pothole bbox RPC, healthcheck function, and stats-refresh cron registration
- `011_pothole_actions.sql` — manual/follow-up pothole canonicalization, 24h same-device dedupe, stale-target rejection, and resolved-pothole reactivation
- `017_segment_contributor_marks.sql` — B166 exact contributor dedupe: the P1-3 single-device inflation reproduction, nightly-recompute mark seeding, and the 6-month GC sweep
- `018_pothole_corroboration_gate.sql` — B165 candidate status and distinct-device promotion across the sensor and manual paths, public-surface invisibility of candidates, reporter-mark exactness, grandfathering, and candidate expiry
- `019_unified_segment_matching.sql` — cross-checks that `match_reading_to_segment` and its three callers (`ingest_reading_batch`, `rematch_readings_after_segment_refresh`, `replay_unmatched_readings`) accept/reject the same tiered-radius and surface-type fixtures identically
- `021_2026_11_backend_hardening.sql` — 2026-11 hardening migrations: day-granular public pothole/worst-segment timestamps, coverage tiles without `updated_at`, k-anonymous `data_updated_at`, per-reading ingest sanitising (heading/accuracy/magnitude), unpaved-nearest matching, replay without double counting, pothole-action time/accuracy bounds, the attested-device upsert guard, retention sweeps, the readings purge, the nightly-recompute watermark and empty-aggregate clearing, the scheduler run ledger, area lock keys, and `finalize_road_segment_refresh`

Fixture time: suites use `now()`-relative timestamps. 004, 005, 006, 011 and
019 were written against fixed 2026 dates; they now shift every fixture by the
same whole number of days (`pg_temp.fixture_ts` / `pg_temp.fixture_jsonb`) so
the base date lands on yesterday (UTC). The suite shares one database across
files and is not re-runnable without `supabase db reset`.
