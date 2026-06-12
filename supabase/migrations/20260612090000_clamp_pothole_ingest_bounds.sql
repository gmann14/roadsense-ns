-- Harden sensor-pothole folding against forged ingest values (P0-1,
-- docs/reviews/2026-06-11-backend-prelaunch-review.md).
--
-- `pothole_magnitude` and `speed_kmh` arrive from the client and were folded
-- into public `pothole_reports` verbatim: a single forged batch could place a
-- max-severity fake pothole on the public map (rendered from z>=8 since
-- 20260505120000). The gateway now validates these fields, but the DB must not
-- trust whatever reaches it either.
--
-- Bounds are taken from the rest of the pipeline, not invented:
-- - The manual report path already clamps sensor-backed magnitude to (0, 8] G
--   (`apply_pothole_action`, 20260425221500). The on-device PotholeDetector
--   documents moderate strikes at ~0.8-1.6 G and deep ones 2 G+; 8 G is far
--   beyond any real suspension event.
-- - `ingest_reading_batch` soft-rejects speed outside 15-160 km/h as
--   `low_quality`; folding keeps its existing >= 45 km/h driving-speed gate
--   (20260506193000) and now also refuses > 160 km/h rows that bypassed ingest.
--
-- Changes to `fold_pothole_candidates` (last-write-wins redefinition of the
-- 20260506193000 body; everything below `batch_candidates` is unchanged):
-- 1. Exclude rows whose `pothole_magnitude` is outside (0, 8] — obviously
--    forged, never folded.
-- 2. Exclude rows with `speed_kmh` > 160 (or somehow negative).
-- 3. Clamp the folded magnitude to [0, 8] even on the legacy
--    NULL-magnitude fallback path, where `roughness_rms` (bounded 0-15 at
--    ingest) could previously exceed the 8 G ceiling.

CREATE OR REPLACE FUNCTION fold_pothole_candidates(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    WITH batch_candidates AS (
        SELECT
            r.segment_id,
            r.location,
            LEAST(
                GREATEST(COALESCE(r.pothole_magnitude, r.roughness_rms), 0),
                8
            )::NUMERIC(4,2) AS magnitude,
            r.recorded_at,
            r.device_token_hash
        FROM readings r
        WHERE r.batch_id = p_batch_id
          AND r.is_pothole = TRUE
          AND r.speed_kmh >= 45
          AND r.speed_kmh <= 160
          AND (
              r.pothole_magnitude IS NULL
              OR (r.pothole_magnitude > 0 AND r.pothole_magnitude <= 8)
          )
          AND r.segment_id IS NOT NULL
    ),
    matched_existing AS (
        SELECT
            bc.segment_id,
            bc.location,
            bc.magnitude,
            bc.recorded_at,
            bc.device_token_hash,
            pr.id AS pothole_id
        FROM batch_candidates bc
        LEFT JOIN LATERAL (
            SELECT pr.id
            FROM pothole_reports pr
            WHERE pr.status = 'active'
              AND pr.segment_id = bc.segment_id
              AND pr.last_confirmed_at >= bc.recorded_at - INTERVAL '90 days'
              AND ST_DWithin(pr.geom::geography, bc.location::geography, 15)
            ORDER BY pr.geom::geography <-> bc.location::geography
            LIMIT 1
        ) pr ON TRUE
    ),
    update_existing AS (
        UPDATE pothole_reports pr
        SET
            last_confirmed_at = GREATEST(pr.last_confirmed_at, agg.last_at),
            confirmation_count = pr.confirmation_count + agg.hit_count,
            unique_reporters = pr.unique_reporters + agg.reporter_count,
            magnitude = GREATEST(pr.magnitude, agg.max_magnitude)
        FROM (
            SELECT
                pothole_id,
                COUNT(*)::INTEGER AS hit_count,
                COUNT(DISTINCT device_token_hash)::INTEGER AS reporter_count,
                MAX(recorded_at) AS last_at,
                MAX(magnitude) AS max_magnitude
            FROM matched_existing
            WHERE pothole_id IS NOT NULL
            GROUP BY pothole_id
        ) agg
        WHERE pr.id = agg.pothole_id
        RETURNING pr.id
    ),
    unmatched AS (
        SELECT
            me.segment_id,
            me.location,
            me.magnitude,
            me.recorded_at,
            me.device_token_hash,
            ST_ClusterDBSCAN(ST_Transform(me.location, 3857), eps := 15, minpoints := 1)
                OVER (PARTITION BY me.segment_id) AS cluster_id
        FROM matched_existing me
        WHERE me.pothole_id IS NULL
    )
    INSERT INTO pothole_reports (
        segment_id,
        geom,
        magnitude,
        first_reported_at,
        last_confirmed_at,
        confirmation_count,
        unique_reporters,
        status
    )
    SELECT
        u.segment_id,
        ST_Centroid(ST_Collect(u.location))::GEOMETRY(POINT, 4326) AS geom,
        MAX(u.magnitude)::NUMERIC(4,2) AS magnitude,
        MIN(u.recorded_at) AS first_reported_at,
        MAX(u.recorded_at) AS last_confirmed_at,
        COUNT(*)::INTEGER AS confirmation_count,
        COUNT(DISTINCT u.device_token_hash)::INTEGER AS unique_reporters,
        'active'::pothole_status
    FROM unmatched u
    GROUP BY u.segment_id, u.cluster_id;
END;
$$;
