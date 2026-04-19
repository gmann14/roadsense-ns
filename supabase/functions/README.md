# Edge Functions

Supabase Edge Functions will live here.

Planned initial functions:

- `upload-readings`
- `tiles`
- `segments`
- `potholes`
- `stats`
- `health`

Phase-2 web additions:

- `tiles-coverage`
- `segments-worst`

Implemented so far:

- `upload-readings`
  - validates request shape, hashes the monthly device token with `TOKEN_PEPPER`, enforces device/IP rate limits, and dispatches to `ingest_reading_batch`
- `tiles`
  - `index.ts` wires the function to the `get_tile` RPC with the service role key
  - `handler.ts` keeps the route parsing, payload normalization, and HTTP contract testable
  - `index_test.ts` covers `200` / `204` / `404` / `405` / `500` behavior without needing a live Supabase stack
- `segments`
  - joins `road_segments` and `segment_aggregates` into the single-segment contract with explicit `history: []` and `neighbors: null` MVP stubs
- `potholes`
  - validates bbox shape/size and reads via the locked `get_potholes_in_bbox` RPC
- `stats`
  - reads `public_stats_mv` and serves the public stats card contract with a 5-minute cache header
- `health`
  - `verify_jwt = false`; proves DB reachability through `db_healthcheck()` and returns deploy metadata
- `tiles-coverage`
  - wraps the service-role `get_coverage_tile` RPC for the public web Coverage mode
  - mirrors the normal tile HTTP contract, but emits `segment_coverage` semantics instead of published-quality-only roads
- `segments-worst`
  - validates `limit` and municipality display names, then reads the ranked `public_worst_segments_mv`
  - returns the public `Worst Roads` report contract with a 15-minute cache header

Local development note:

- put function-only secrets such as `TOKEN_PEPPER` in `supabase/functions/.env`
- keep that file uncommitted
