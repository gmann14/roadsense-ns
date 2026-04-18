CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(16);

TRUNCATE road_segments_staging;

DROP TABLE IF EXISTS osm.osm_nodes;
DROP TABLE IF EXISTS osm.osm_ways;
DROP TABLE IF EXISTS ref.municipalities;

CREATE TABLE osm.osm_ways (
    osm_id BIGINT PRIMARY KEY,
    name TEXT,
    highway TEXT,
    surface TEXT,
    service TEXT,
    access TEXT,
    traffic_calming TEXT,
    railway TEXT,
    geom GEOMETRY(LINESTRING, 4326) NOT NULL
);

CREATE TABLE osm.osm_nodes (
    osm_id BIGINT PRIMARY KEY,
    traffic_calming TEXT,
    railway TEXT,
    geom GEOMETRY(POINT, 4326) NOT NULL
);

CREATE TABLE ref.municipalities (
    csd_name TEXT PRIMARY KEY,
    geom GEOMETRY(MULTIPOLYGON, 4326) NOT NULL
);

WITH
halifax_base AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-63.575, 44.648), 4326), 3857) AS p
),
dartmouth_base AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-63.565, 44.650), 4326), 3857) AS p
)
INSERT INTO osm.osm_ways (
    osm_id,
    name,
    highway,
    surface,
    service,
    access,
    traffic_calming,
    railway,
    geom
)
SELECT
    910001,
    'Main Street',
    'primary',
    'asphalt',
    NULL,
    NULL,
    NULL,
    NULL,
    ST_Transform(ST_MakeLine(p, ST_Translate(p, 120, 0)), 4326)
FROM halifax_base
UNION ALL
SELECT
    910002,
    'Lot Aisle',
    'service',
    'asphalt',
    'parking_aisle',
    NULL,
    NULL,
    NULL,
    ST_Transform(ST_MakeLine(p, ST_Translate(p, 70, 0)), 4326)
FROM dartmouth_base;

WITH
halifax_base AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-63.575, 44.648), 4326), 3857) AS p
),
dartmouth_base AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-63.565, 44.650), 4326), 3857) AS p
)
INSERT INTO osm.osm_nodes (
    osm_id,
    traffic_calming,
    railway,
    geom
)
SELECT
    920001,
    'bump',
    NULL,
    ST_Transform(ST_Translate(p, 10, 0), 4326)
FROM halifax_base
UNION ALL
SELECT
    920002,
    NULL,
    'level_crossing',
    ST_Transform(ST_Translate(p, 10, 0), 4326)
FROM dartmouth_base;

WITH
halifax_base AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-63.575, 44.648), 4326), 3857) AS p
),
dartmouth_base AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-63.565, 44.650), 4326), 3857) AS p
)
INSERT INTO ref.municipalities (
    csd_name,
    geom
)
SELECT
    'Halifax',
    ST_Multi(ST_Transform(ST_Buffer(ST_Translate(p, 60, 0), 150), 4326))
FROM halifax_base
UNION ALL
SELECT
    'Dartmouth',
    ST_Multi(ST_Transform(ST_Buffer(ST_Translate(p, 35, 0), 150), 4326))
FROM dartmouth_base;

SELECT lives_ok(
    $$SELECT stage_osm_segments()$$,
    'stage_osm_segments runs successfully'
);

SELECT lives_ok(
    $$SELECT tag_staged_municipalities()$$,
    'tag_staged_municipalities runs successfully'
);

SELECT lives_ok(
    $$SELECT tag_staged_features()$$,
    'tag_staged_features runs successfully'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging),
    5,
    'fixture import yields five staged segments'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging WHERE osm_way_id = 910001),
    3,
    '120m primary way becomes three segments'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging WHERE osm_way_id = 910002),
    2,
    '70m parking aisle way becomes two segments'
);

SELECT is(
    (SELECT length_m::TEXT FROM road_segments_staging WHERE osm_way_id = 910001 AND segment_index = 2),
    '20.0',
    'tail segment keeps the remainder length'
);

SELECT is(
    (SELECT count(DISTINCT (osm_way_id, segment_index))::INTEGER FROM road_segments_staging),
    5,
    'staged segments remain unique on osm_way_id and segment_index'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging WHERE osm_way_id = 910001 AND municipality = 'Halifax'),
    3,
    'primary-road segments pick up the Halifax municipality'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging WHERE osm_way_id = 910002 AND municipality = 'Dartmouth'),
    2,
    'parking-aisle segments pick up the Dartmouth municipality'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM road_segments_staging
        WHERE osm_way_id = 910001
          AND has_speed_bump
    ),
    'speed bump node tags the nearby staged segment'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM road_segments_staging
        WHERE osm_way_id = 910002
          AND has_rail_crossing
    ),
    'rail crossing node tags the nearby staged segment'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging WHERE osm_way_id = 910002 AND is_parking_aisle),
    2,
    'parking aisle derives from the OSM service tag during segmentization'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM road_segments_staging WHERE bearing_degrees IS NOT NULL),
    5,
    'all staged fixture segments keep a computed bearing'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.stage_osm_segments()', 'EXECUTE'),
    'anon cannot execute stage_osm_segments'
);

SELECT ok(
    has_function_privilege('service_role', 'public.tag_staged_features()', 'EXECUTE'),
    'service_role can execute tag_staged_features'
);

SELECT * FROM finish();
