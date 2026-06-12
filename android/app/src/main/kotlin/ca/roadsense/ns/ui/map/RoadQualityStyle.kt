package ca.roadsense.ns.ui.map

/**
 * Shared style constants for the road-quality + pothole layers. Kept as a
 * pure-Kotlin object so:
 *  - JVM unit tests can lock the source-layer names + ramp colors against
 *    iOS / web parity without spinning up the Mapbox SDK
 *  - the `MapboxBridge` Mapbox-typed code can reference the same constants
 *  - the WebView fallback can also stay aligned should it ever stop pointing
 *    at the prebuilt web map
 *
 * Source-layer names ("segment_aggregates", "potholes") MUST match the iOS
 * `RoadQualityMapStyleContent` in `ios/.../Features/Map/RoadQualityMapView.swift`
 * and the backend `/tiles/{z}/{x}/{y}.mvt` Edge Function shape declared in
 * `docs/implementation/03-api-contracts.md`.
 */
object RoadQualityStyle {
    /** Source ids — local to this client, do not need to match iOS, but kept
     *  consistent so two engineers comparing the Mapbox debug overlays see
     *  the same node names. */
    const val SEGMENT_SOURCE_ID = "roadsense-quality-source"
    const val POTHOLE_SOURCE_ID = "roadsense-pothole-source"

    /** Layer ids. */
    const val SEGMENT_LAYER_ID = "roadsense-quality-line"
    const val POTHOLE_LAYER_ID = "roadsense-potholes"

    /** Vector source-layer names baked into the MVTs the backend emits. */
    const val SEGMENT_SOURCE_LAYER = "segment_aggregates"
    const val POTHOLE_SOURCE_LAYER = "potholes"

    /** Tile zoom bounds for the segment + pothole layers. Mirrors iOS. */
    const val SEGMENT_MIN_ZOOM = 10
    const val SEGMENT_MAX_ZOOM = 16
    const val POTHOLE_MIN_ZOOM = 13
    const val POTHOLE_MAX_ZOOM = 16

    /** Default Halifax-centered camera for the in-app map shell. */
    const val DEFAULT_CENTER_LAT = 44.6488
    const val DEFAULT_CENTER_LNG = -63.5752
    const val DEFAULT_ZOOM = 11.5

    /** Road-quality ramp colors. Hex bodies mirror `DesignTokens.Palette` in
     *  `ios/.../Features/DesignSystem/DesignTokens.swift`. Keep them in sync;
     *  the unit test in `RoadQualityStyleTest` will scream if they drift. */
    const val COLOR_SMOOTH = "#2F8F6D"
    const val COLOR_FAIR = "#E2B341"
    const val COLOR_ROUGH = "#D97636"
    const val COLOR_VERY_ROUGH = "#C04242"
    const val COLOR_UNPAVED = "#8A9AA2"

    /** Used both as "the segment is unpaved" highlight on iOS and as a
     *  semantic warning color elsewhere; matches `Palette.warning`. */
    const val COLOR_WARNING = "#D97636"

    /** Light-mode `Palette.inkMuted`; used as the unknown-category fallback. */
    const val COLOR_UNKNOWN = "#55707D"

    /** Confidence-band opacities, matched line-for-line to iOS. */
    const val OPACITY_LOW_CONFIDENCE = 0.4
    const val OPACITY_MEDIUM_CONFIDENCE = 0.72
    const val OPACITY_HIGH_CONFIDENCE = 0.96

    /** Map a category enum string (as emitted by the tile MVT) to its
     *  ramp color. Used by the JVM test + the live Mapbox style. */
    fun categoryColor(category: String?): String = when (category) {
        "smooth" -> COLOR_SMOOTH
        "fair" -> COLOR_FAIR
        "rough" -> COLOR_ROUGH
        "very_rough" -> COLOR_VERY_ROUGH
        "unpaved" -> COLOR_UNPAVED
        else -> COLOR_UNKNOWN
    }
}
