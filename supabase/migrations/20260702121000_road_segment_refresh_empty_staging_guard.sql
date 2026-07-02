-- P0: apply_road_segment_refresh() can silently wipe the entire road network.
--
-- The function's final step is:
--   DELETE FROM road_segments rs
--   WHERE NOT EXISTS (SELECT 1 FROM road_segments_staging s WHERE ...)
-- with no guard on the size or presence of road_segments_staging. If the OSM
-- import that populates staging fails partway, is run out of order, or is
-- simply empty (e.g. a fresh environment before the first `stage_osm_segments()`
-- call), this DELETE matches every row in road_segments — deleting the whole
-- road network in one statement, cascading (ON DELETE CASCADE /
-- ON DELETE SET NULL, see 20260418093xxx table definitions) into
-- segment_aggregates and segment_contributor_marks.
--
-- Fix: raise before the merge/delete if staging is empty, or if staging has
-- collapsed to well under the current road_segments size. Threshold picked at
-- 50% — legitimate NS-wide re-imports can plausibly add or retire segments as
-- OSM data or the extraction bounds change, but a >50% drop in one refresh is
-- always evidence of a broken/partial import, never an intentional edit. This
-- is deliberately a coarse "obviously broken" tripwire, not a general staging
-- QA gate — a corrupt-but-similarly-sized import can still get through and
-- needs its own validation.
--
-- On the very first refresh (road_segments empty), the ratio check is skipped
-- since there is nothing to compare against yet; only the "staging is empty"
-- check applies.

CREATE OR REPLACE FUNCTION apply_road_segment_refresh()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_staging_count BIGINT;
    v_current_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_staging_count FROM road_segments_staging;
    SELECT COUNT(*) INTO v_current_count FROM road_segments;

    IF v_staging_count = 0 THEN
        RAISE EXCEPTION 'apply_road_segment_refresh: road_segments_staging is empty; refusing to delete all % existing road_segments. Re-run stage_osm_segments() (and tag_staged_municipalities()/tag_staged_features()) before retrying.', v_current_count
            USING ERRCODE = 'P0001';
    END IF;

    IF v_current_count > 0 AND v_staging_count < (v_current_count * 0.5) THEN
        RAISE EXCEPTION 'apply_road_segment_refresh: road_segments_staging has % rows, less than half of the % rows currently in road_segments; refusing to run what looks like a truncated/corrupt import. If this drop is intentional, verify the staging data and call the merge steps directly.', v_staging_count, v_current_count
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE road_segments rs
    SET
        geom = s.geom,
        length_m = s.length_m,
        road_name = s.road_name,
        road_type = s.road_type,
        surface_type = s.surface_type,
        municipality = s.municipality,
        has_speed_bump = COALESCE(s.has_speed_bump, FALSE),
        has_rail_crossing = COALESCE(s.has_rail_crossing, FALSE),
        is_parking_aisle = COALESCE(s.is_parking_aisle, FALSE),
        bearing_degrees = s.bearing_degrees,
        updated_at = now()
    FROM road_segments_staging s
    WHERE rs.osm_way_id = s.osm_way_id
      AND rs.segment_index = s.segment_index;

    INSERT INTO road_segments (
        osm_way_id,
        segment_index,
        geom,
        length_m,
        road_name,
        road_type,
        surface_type,
        municipality,
        has_speed_bump,
        has_rail_crossing,
        is_parking_aisle,
        bearing_degrees
    )
    SELECT
        s.osm_way_id,
        s.segment_index,
        s.geom,
        s.length_m,
        s.road_name,
        s.road_type,
        s.surface_type,
        s.municipality,
        COALESCE(s.has_speed_bump, FALSE),
        COALESCE(s.has_rail_crossing, FALSE),
        COALESCE(s.is_parking_aisle, FALSE),
        s.bearing_degrees
    FROM road_segments_staging s
    LEFT JOIN road_segments rs
        ON rs.osm_way_id = s.osm_way_id
       AND rs.segment_index = s.segment_index
    WHERE rs.id IS NULL;

    DELETE FROM road_segments rs
    WHERE NOT EXISTS (
        SELECT 1
        FROM road_segments_staging s
        WHERE s.osm_way_id = rs.osm_way_id
          AND s.segment_index = rs.segment_index
    );
END;
$$;

COMMENT ON FUNCTION apply_road_segment_refresh() IS
    'Merges road_segments_staging into road_segments (update matching, insert new, delete stale). Refuses to run (RAISE EXCEPTION P0001) if staging is empty or has collapsed to under 50% of the current road_segments row count, to guard against a failed/partial/out-of-order OSM import silently deleting the whole road network. See 20260702121000_road_segment_refresh_empty_staging_guard.sql.';

REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM anon;
REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM authenticated;
GRANT EXECUTE ON FUNCTION apply_road_segment_refresh() TO service_role;
