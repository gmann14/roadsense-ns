package ca.roadsense.ns.ui.map

/**
 * Pure-data input for [MapboxBridge.createMapView]. Lives in shared `main` so
 * MapHost and the two MapboxBridge variants (mapboxMain vs noMapboxMain) can
 * both depend on it without dragging the Mapbox SDK into the no-Mapbox build.
 *
 * The defaults are Halifax, NS — same starting center the iOS app uses when
 * it has no last-known location.
 */
data class MapboxConfig(
    val tileTemplateURL: String,
    val accessToken: String,
    val initialLat: Double = RoadQualityStyle.DEFAULT_CENTER_LAT,
    val initialLng: Double = RoadQualityStyle.DEFAULT_CENTER_LNG,
    val initialZoom: Double = RoadQualityStyle.DEFAULT_ZOOM,
)
