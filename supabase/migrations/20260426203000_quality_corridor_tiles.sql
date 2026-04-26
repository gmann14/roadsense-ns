CREATE OR REPLACE FUNCTION get_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_tile BYTEA;
BEGIN
    IF z < 8 THEN
        RETURN ''::BYTEA;
    END IF;

    WITH bounds AS (
        SELECT
            ST_TileEnvelope(z, x, y) AS geom_3857,
            ST_Transform(ST_TileEnvelope(z, x, y), 4326) AS geom_4326
    ),
    scored_segments AS MATERIALIZED (
        SELECT
            rs.id,
            rs.road_name,
            rs.road_type,
            rs.geom AS segment_geom,
            sa.avg_roughness_score AS roughness_score,
            sa.roughness_category::TEXT AS category,
            sa.confidence::TEXT AS confidence,
            sa.total_readings,
            sa.unique_contributors,
            sa.pothole_count
        FROM segment_aggregates sa
        JOIN road_segments rs
          ON rs.id = sa.segment_id
        WHERE sa.total_readings > 0
          AND rs.is_parking_aisle = FALSE
    ),
    corridor_candidates AS (
        SELECT
            COALESCE(ss.road_name, 'Unnamed road') AS road_name,
            ST_LineMerge(
                ST_CollectionExtract(
                    ST_UnaryUnion(ST_Collect(ss.segment_geom)),
                    2
                )
            ) AS corridor_geom
        FROM bounds b
        JOIN scored_segments ss
          ON ss.segment_geom && b.geom_4326
        WHERE ST_Intersects(ST_Transform(ss.segment_geom, 3857), b.geom_3857)
        GROUP BY COALESCE(ss.road_name, 'Unnamed road')
    ),
    corridors AS (
        SELECT
            cc.road_name,
            ST_AsMVTGeom(
                ST_Transform(cc.corridor_geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        CROSS JOIN corridor_candidates cc
        WHERE NOT ST_IsEmpty(cc.corridor_geom)
    ),
    segments AS (
        SELECT
            ss.id,
            ss.road_name,
            ss.road_type,
            ss.roughness_score,
            ss.category,
            ss.confidence,
            ss.total_readings,
            ss.unique_contributors,
            ss.pothole_count,
            ST_AsMVTGeom(
                ST_Transform(ss.segment_geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN scored_segments ss
          ON ss.segment_geom && b.geom_4326
        WHERE ST_Intersects(ST_Transform(ss.segment_geom, 3857), b.geom_3857)
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
                SELECT ST_AsMVT(corridor_rows.*, 'quality_corridors', 4096, 'geom')
                FROM corridors AS corridor_rows
            ),
            ''::BYTEA
        ) ||
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
