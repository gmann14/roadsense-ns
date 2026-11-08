-- N5 / P1-s3 follow-up (docs/reviews/2026-10-18-full-codebase-review.md).
--
-- 20260702130000_stage_osm_segments_geography_length.sql fixed
-- `stage_osm_segments` to measure length with `geom::geography`, but nothing
-- backfilled the rows already in `road_segments`: their `length_m` is still
-- the Web-Mercator planar length, ~1.41x too long at Nova Scotia's latitude,
-- so `public_stats_mv.total_km_mapped` (the public "km mapped" headline) is
-- ~40% high.
--
-- 1. Backfill `road_segments.length_m` from the stored geometry. This only
--    rewrites the length column; segment geometry, ids and aggregates are
--    untouched. `public_stats_mv` is rebuilt (and so re-summed) by
--    20261108100000_public_privacy_floor.sql, which runs right after this.
--
-- 2. `finalize_road_segment_refresh()`: the post-refresh step the next OSM
--    import MUST run. The geography-length fix means the next
--    `stage_osm_segments()` re-cuts every way into true 50 m pieces, but
--    `road_segments` rows are keyed by (osm_way_id, segment_index). After the
--    re-cut, index k of a way describes a different stretch of road while
--    still carrying the old aggregates; the tail indexes that no longer exist
--    are deleted (cascading their aggregates and contributor marks, nulling
--    `pothole_reports.segment_id`). `apply_road_segment_refresh()` alone
--    therefore leaves public scores attached to the wrong pavement. This
--    function re-matches retained readings against the new network,
--    recomputes every segment that has readings or an aggregate, rebuilds the
--    contributor marks, and re-anchors open potholes to their nearest
--    current segment. Run it in the same transaction as the merge:
--
--        BEGIN;
--        SELECT apply_road_segment_refresh();
--        SELECT finalize_road_segment_refresh();
--        COMMIT;
--
--    It is deliberately NOT called from inside apply_road_segment_refresh():
--    the merge stays a pure merge (tests 002/004 exercise it in isolation)
--    and the full recompute is an explicit, visible step in the import
--    runbook (docs/implementation/02-backend-implementation.md).

UPDATE road_segments
SET length_m = ROUND(ST_Length(geom::geography)::NUMERIC, 1)
WHERE length_m IS DISTINCT FROM ROUND(ST_Length(geom::geography)::NUMERIC, 1);

CREATE OR REPLACE FUNCTION finalize_road_segment_refresh(
    p_since TIMESTAMPTZ DEFAULT now() - INTERVAL '6 months'
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_touched UUID[];
    v_recompute UUID[];
    v_potholes_reanchored INTEGER := 0;
BEGIN
    -- Readings follow the new geometry first (shared matcher criteria).
    v_touched := rematch_readings_after_segment_refresh(p_since);

    -- Every segment that still has retained readings or carries an aggregate
    -- is recomputed, not just the ones whose reading membership changed: a
    -- surviving (osm_way_id, segment_index) id can now describe a different
    -- stretch of road with no reading having moved at all.
    SELECT COALESCE(array_agg(DISTINCT sid), ARRAY[]::UUID[])
    INTO v_recompute
    FROM (
        SELECT r.segment_id AS sid
        FROM readings r
        WHERE r.segment_id IS NOT NULL
          AND r.recorded_at > now() - INTERVAL '6 months'
        UNION
        SELECT sa.segment_id
        FROM segment_aggregates sa
    ) s
    WHERE EXISTS (SELECT 1 FROM road_segments rs WHERE rs.id = s.sid);

    -- Marks are keyed by segment id, so pre-refresh marks describe the old
    -- geometry. The recompute below re-seeds them from the rematched
    -- readings (nightly_recompute_aggregates inserts one mark per
    -- (segment, device) in its target set).
    DELETE FROM segment_contributor_marks;

    IF cardinality(v_recompute) > 0 THEN
        PERFORM nightly_recompute_aggregates(v_recompute);
    END IF;

    -- fold_pothole_candidates matches existing potholes by segment_id, so an
    -- open pothole left pointing at a re-cut (or deleted -> NULL) segment
    -- would never be corroborated again. Re-anchor to the nearest current
    -- non-parking-aisle segment within the 30 m manual-report radius; keep
    -- the existing value when nothing is in range.
    WITH nearest AS (
        SELECT pr.id AS pothole_id, n.segment_id
        FROM pothole_reports pr
        CROSS JOIN LATERAL (
            SELECT rs.id AS segment_id
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, pr.geom::geography, 30)
              AND rs.is_parking_aisle = FALSE
            ORDER BY rs.geom::geography <-> pr.geom::geography
            LIMIT 1
        ) n
        WHERE pr.status IN ('active', 'candidate')
    )
    UPDATE pothole_reports pr
    SET segment_id = nearest.segment_id
    FROM nearest
    WHERE pr.id = nearest.pothole_id
      AND pr.segment_id IS DISTINCT FROM nearest.segment_id;
    GET DIAGNOSTICS v_potholes_reanchored = ROW_COUNT;

    RETURN jsonb_build_object(
        'segments_touched_by_rematch', COALESCE(cardinality(v_touched), 0),
        'segments_recomputed', cardinality(v_recompute),
        'potholes_reanchored', v_potholes_reanchored
    );
END;
$$;

COMMENT ON FUNCTION finalize_road_segment_refresh(TIMESTAMPTZ) IS
    'Post-OSM-refresh consistency step: rematch retained readings, rebuild contributor marks, recompute every segment with readings or an aggregate (clearing aggregates left with no readings), and re-anchor open potholes to their nearest current segment. Run in the same transaction as apply_road_segment_refresh(). See 20261108090000_backfill_segment_length_and_refresh_finalize.sql and docs/implementation/02-backend-implementation.md.';

REVOKE EXECUTE ON FUNCTION finalize_road_segment_refresh(TIMESTAMPTZ) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION finalize_road_segment_refresh(TIMESTAMPTZ) FROM anon;
REVOKE EXECUTE ON FUNCTION finalize_road_segment_refresh(TIMESTAMPTZ) FROM authenticated;
GRANT EXECUTE ON FUNCTION finalize_road_segment_refresh(TIMESTAMPTZ) TO service_role;
