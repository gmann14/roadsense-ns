-- Lower the tile-render floor from z<10 (file) / z<8 (drifted prod) to
-- z<6 so the public web map shows roughness segments at any reasonable
-- province-wide zoom, including the auto-fit-to-data initial view that
-- lands around z=7.5-8 for Nova Scotia-wide scored-segment extents.
--
-- The existing CASE in the segments CTE keeps z<12 limited to major
-- roads (motorway / trunk / primary / secondary + their _link variants),
-- so the new z=6/z=7/z=8/z=9 tiers never render more than ~932 segments
-- province-wide. Tile size stays cheap.
--
-- Also forces a one-shot refresh of public_stats_mv so map_bounds is
-- current. The nightly cron job keeps it fresh after this point.
--
-- Reference: field-test 2026-05-05 — home page rendered an empty NS
-- view because the auto-fit-to-data viewport landed at z≈7-8 which was
-- below the tile-rendering floor.
--
-- Note: production drift — the prod get_tile was already at z<8 via an
-- ad-hoc fix not represented in migrations. This migration brings the
-- repo and prod back in line and goes further to z<6.

CREATE OR REPLACE FUNCTION get_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tile BYTEA;
BEGIN
    IF z < 6 THEN
        RETURN ''::BYTEA;
    END IF;

    WITH bounds AS (
        SELECT
            ST_TileEnvelope(z, x, y) AS geom_3857,
            ST_Transform(ST_TileEnvelope(z, x, y), 4326) AS geom_4326
    ),
    segments AS (
        SELECT
            rs.id,
            rs.road_name,
            rs.road_type,
            sa.avg_roughness_score AS roughness_score,
            sa.roughness_category::TEXT AS category,
            sa.confidence::TEXT AS confidence,
            sa.total_readings,
            sa.unique_contributors,
            sa.pothole_count,
            ST_AsMVTGeom(
                ST_Transform(rs.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN road_segments rs
          ON rs.geom && b.geom_4326
        JOIN segment_aggregates sa
          ON sa.segment_id = rs.id
        WHERE ST_Intersects(ST_Transform(rs.geom, 3857), b.geom_3857)
          AND rs.is_parking_aisle = FALSE
          AND CASE
              WHEN z < 12 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link'
              )
              WHEN z < 14 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link'
              )
              ELSE TRUE
          END
    ),
    potholes AS (
        SELECT
            pr.id,
            pr.magnitude,
            pr.confirmation_count,
            ST_AsMVTGeom(
                ST_Transform(pr.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN pothole_reports pr
          ON pr.geom && b.geom_4326
        WHERE pr.status = 'active'
          AND z >= 12
          AND ST_Intersects(ST_Transform(pr.geom, 3857), b.geom_3857)
    )
    SELECT
        COALESCE(
            (
                SELECT ST_AsMVT(segment_rows.*, 'segment_aggregates', 4096, 'geom')
                FROM segments AS segment_rows
            ),
            ''::BYTEA
        ) ||
        COALESCE(
            (
                SELECT ST_AsMVT(pothole_rows.*, 'potholes', 4096, 'geom')
                FROM potholes AS pothole_rows
            ),
            ''::BYTEA
        )
    INTO v_tile;

    RETURN COALESCE(v_tile, ''::BYTEA);
END;
$$;

REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv;
