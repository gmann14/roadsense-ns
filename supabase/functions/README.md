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
