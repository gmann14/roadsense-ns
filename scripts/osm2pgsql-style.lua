local schema = 'osm'

local ways = osm2pgsql.define_way_table('osm_ways', {
    { column = 'name', type = 'text' },
    { column = 'highway', type = 'text' },
    { column = 'surface', type = 'text' },
    { column = 'service', type = 'text' },
    { column = 'access', type = 'text' },
    { column = 'traffic_calming', type = 'text' },
    { column = 'railway', type = 'text' },
    { column = 'geom', type = 'linestring', projection = 4326 },
}, {
    schema = schema,
    ids = { type = 'way', id_column = 'osm_id' }
})

local nodes = osm2pgsql.define_node_table('osm_nodes', {
    { column = 'traffic_calming', type = 'text' },
    { column = 'railway', type = 'text' },
    { column = 'geom', type = 'point', projection = 4326 },
}, {
    schema = schema,
    ids = { type = 'node', id_column = 'osm_id' }
})

local drivable_highways = {
    motorway = true,
    trunk = true,
    primary = true,
    secondary = true,
    tertiary = true,
    residential = true,
    unclassified = true,
    service = true,
    motorway_link = true,
    trunk_link = true,
    primary_link = true,
    secondary_link = true,
    tertiary_link = true,
    living_street = true,
    track = true,
}

function osm2pgsql.process_way(object)
    local highway = object.tags.highway
    if not highway or not drivable_highways[highway] then
        return
    end

    ways:insert({
        name = object.tags.name,
        highway = highway,
        surface = object.tags.surface,
        service = object.tags.service,
        access = object.tags.access,
        traffic_calming = object.tags.traffic_calming,
        railway = object.tags.railway,
        geom = object:as_linestring(),
    })
end

function osm2pgsql.process_node(object)
    if not object.tags.traffic_calming and not object.tags.railway then
        return
    end

    nodes:insert({
        traffic_calming = object.tags.traffic_calming,
        railway = object.tags.railway,
        geom = object:as_point(),
    })
end
