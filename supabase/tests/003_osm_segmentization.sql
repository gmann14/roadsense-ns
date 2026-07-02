CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(18);

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

-- Way geometries are built with ST_Project on geography (true geodesic
-- distance + azimuth from the origin point), NOT by translating in EPSG:3857
-- meters. At this fixture's ~44.65 degN latitude, Web Mercator overstates
-- distance by roughly 1/cos(latitude) (~1.40x), so a naive 3857 translation
-- of "120 meters" is only ~85.4 true ground meters — exactly the P1 bug this
-- suite now guards against (20260702130000_stage_osm_segments_geography_length.sql).
-- ST_Project gives an exact, latitude-correct ground distance, so the
-- resulting ways are genuinely 120m/70m long and the segment-count/length
-- assertions below are unambiguous.
WITH
halifax_base AS (
    SELECT ST_SetSRID(ST_MakePoint(-63.575, 44.648), 4326) AS p
),
dartmouth_base AS (
    SELECT ST_SetSRID(ST_MakePoint(-63.565, 44.650), 4326) AS p
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
    ST_MakeLine(
        p,
        ST_SetSRID(ST_Project(p::geography, 120, radians(90))::geometry, 4326)
    )
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
    ST_MakeLine(
        p,
        ST_SetSRID(ST_Project(p::geography, 70, radians(90))::geometry, 4326)
    )
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

-- P1: Web-Mercator segment lengths overstate ~40% at Nova Scotia latitude.
-- stage_osm_segments() used to measure length with
-- ST_Length(ST_Transform(geom, 3857)), which inflates true ground distance by
-- roughly 1/cos(latitude) — about 1.40x (a ~40% overstatement) at 44.65 degN.
-- The 120m/70m fixture ways above are built with ST_Project (true geodesic
-- distance), so their aggregate staged length_m should sum back to ~120/~70
-- true meters, not ~168/~98 (what the old Mercator-based code would have
-- reported). A generous 2% tolerance absorbs float/geodesic-vs-line-segment
-- rounding while still failing hard on a ~40% latitude-inflation regression.
SELECT ok(
    abs((SELECT SUM(length_m) FROM road_segments_staging WHERE osm_way_id = 910001) - 120.0) < 2.4,
    'primary way staged length_m sums to true ~120m, not the ~40% Web-Mercator-inflated ~168m'
);

SELECT ok(
    abs((SELECT SUM(length_m) FROM road_segments_staging WHERE osm_way_id = 910002) - 70.0) < 1.4,
    'parking-aisle way staged length_m sums to true ~70m, not the ~40% Web-Mercator-inflated ~98m'
);

SELECT * FROM finish();
