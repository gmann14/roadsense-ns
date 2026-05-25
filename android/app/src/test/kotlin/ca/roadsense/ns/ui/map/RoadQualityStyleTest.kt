package ca.roadsense.ns.ui.map

import org.junit.Test
import kotlin.test.assertEquals

/**
 * Locks the road-quality + pothole style constants against the iOS source
 * of truth. Drift here means iOS, web, and Android stop agreeing on the
 * roughness ramp.
 *
 * iOS source: `ios/RoadSenseNS/Features/Map/RoadQualityMapView.swift`
 * iOS palette: `ios/RoadSenseNS/Features/DesignSystem/DesignTokens.swift`
 * Backend wire shape: `docs/implementation/03-api-contracts.md` —
 *   `GET /tiles/{z}/{x}/{y}.mvt` → source-layers `segment_aggregates` +
 *   `potholes`.
 */
class RoadQualityStyleTest {

    @Test
    fun sourceLayerNamesMatchTheTileEndpointContract() {
        // These two strings are the contract — flip either and every iOS or
        // web build that already speaks the same MVT will stop rendering.
        assertEquals("segment_aggregates", RoadQualityStyle.SEGMENT_SOURCE_LAYER)
        assertEquals("potholes", RoadQualityStyle.POTHOLE_SOURCE_LAYER)
    }

    @Test
    fun zoomBoundsMatchTheIOSStyleContent() {
        // Mirrors `VectorSource.minzoom(10).maxzoom(16)` for segments and the
        // pothole layer's narrower 13–16 window in the iOS style content.
        assertEquals(10, RoadQualityStyle.SEGMENT_MIN_ZOOM)
        assertEquals(16, RoadQualityStyle.SEGMENT_MAX_ZOOM)
        assertEquals(13, RoadQualityStyle.POTHOLE_MIN_ZOOM)
        assertEquals(16, RoadQualityStyle.POTHOLE_MAX_ZOOM)
    }

    @Test
    fun rampColorsMatchIOSDesignTokensPalette() {
        // Hex bodies must equal `DesignTokens.Palette.{smooth,fair,rough,veryRough,unpaved,warning}`.
        assertEquals("#2F8F6D", RoadQualityStyle.COLOR_SMOOTH)
        assertEquals("#E2B341", RoadQualityStyle.COLOR_FAIR)
        assertEquals("#D97636", RoadQualityStyle.COLOR_ROUGH)
        assertEquals("#C04242", RoadQualityStyle.COLOR_VERY_ROUGH)
        assertEquals("#8A9AA2", RoadQualityStyle.COLOR_UNPAVED)
        assertEquals("#D97636", RoadQualityStyle.COLOR_WARNING)
        // `Palette.inkMuted` light-mode value, used as the unknown-category fallback.
        assertEquals("#55707D", RoadQualityStyle.COLOR_UNKNOWN)
    }

    @Test
    fun confidenceOpacityBandsMatchIOSStyleContent() {
        assertEquals(0.4, RoadQualityStyle.OPACITY_LOW_CONFIDENCE, 0.0)
        assertEquals(0.72, RoadQualityStyle.OPACITY_MEDIUM_CONFIDENCE, 0.0)
        assertEquals(0.96, RoadQualityStyle.OPACITY_HIGH_CONFIDENCE, 0.0)
    }

    @Test
    fun categoryColorReturnsRampForEveryKnownCategory() {
        // Matches the iOS `Exp(.match) { Exp(.get) { "category" } ... }`
        // explicitly so the JVM test catches drift before it ever ships.
        assertEquals(RoadQualityStyle.COLOR_SMOOTH, RoadQualityStyle.categoryColor("smooth"))
        assertEquals(RoadQualityStyle.COLOR_FAIR, RoadQualityStyle.categoryColor("fair"))
        assertEquals(RoadQualityStyle.COLOR_ROUGH, RoadQualityStyle.categoryColor("rough"))
        assertEquals(RoadQualityStyle.COLOR_VERY_ROUGH, RoadQualityStyle.categoryColor("very_rough"))
        assertEquals(RoadQualityStyle.COLOR_UNPAVED, RoadQualityStyle.categoryColor("unpaved"))
    }

    @Test
    fun categoryColorFallsBackForUnknownInputs() {
        // Mirrors the iOS expression default branch and protects against
        // backend additions silently rendering invisible.
        assertEquals(RoadQualityStyle.COLOR_UNKNOWN, RoadQualityStyle.categoryColor("brand_new_bucket"))
        assertEquals(RoadQualityStyle.COLOR_UNKNOWN, RoadQualityStyle.categoryColor(null))
        assertEquals(RoadQualityStyle.COLOR_UNKNOWN, RoadQualityStyle.categoryColor(""))
    }

    @Test
    fun defaultCameraSitsInHalifax() {
        // Sanity check that the in-app shell opens on the right hemisphere.
        // Halifax is roughly 44.65 N, 63.58 W — the values here just need
        // to fall inside a generous NS bounding box.
        val lat = RoadQualityStyle.DEFAULT_CENTER_LAT
        val lng = RoadQualityStyle.DEFAULT_CENTER_LNG
        assert(lat in 43.0..47.5) { "lat $lat outside NS bounding box" }
        assert(lng in -67.0..-59.0) { "lng $lng outside NS bounding box" }
        assert(RoadQualityStyle.DEFAULT_ZOOM in 9.0..14.0) {
            "default zoom ${RoadQualityStyle.DEFAULT_ZOOM} outside reasonable city range"
        }
    }
}
