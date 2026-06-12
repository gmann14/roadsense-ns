package ca.roadsense.ns.ui.map

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/**
 * Pinned tests for the no-Mapbox build flavor. CI runs without
 * `MAPBOX_DOWNLOADS_TOKEN` set, so this is the [MapboxBridge] that ends up
 * on the test classpath. Sub-goals:
 *  - `isAvailable` is `false`, so `MapHost` reliably falls through to the
 *    WebView path on the public clone
 *  - `createMapView` throws loudly rather than returning a blank surface,
 *    so an accidental caller surfaces in CI rather than at runtime
 *  - the shared [MapboxConfig] default camera lines up with the
 *    [RoadQualityStyle] defaults
 *
 * If you are reading this on a machine that *did* sync with the private
 * Mapbox Maven, the real `MapboxBridge.isAvailable` is `true` and this
 * test is intentionally skipped by the early return below — the live
 * bridge cannot exercise its `MapView` constructor on the JVM because
 * Mapbox's native libraries are Android-only.
 */
class MapboxBridgeStubTest {

    @Test
    fun stubReportsUnavailableAndThrowsOnCreate() {
        if (MapboxBridge.isAvailable) {
            // Real bridge loaded. The JVM unit-test process cannot start a
            // native MapView (no Android runtime), so there is no useful
            // behavior to lock down here.
            return
        }
        assertFalse(MapboxBridge.isAvailable, "no-Mapbox build should report unavailable")
        val ex = assertFailsWith<IllegalStateException> {
            MapboxBridge.createMapView(
                context = throwingContext(),
                config = MapboxConfig(
                    tileTemplateURL = "https://example/tiles/{z}/{x}/{y}.mvt",
                    accessToken = "pk.placeholder",
                ),
            )
        }
        // The message tells the next engineer what to do — if it ever stops
        // mentioning the token name, the runbook in
        // docs/implementation/15-google-play-readiness.md will drift.
        assert(ex.message?.contains("MAPBOX_DOWNLOADS_TOKEN") == true) {
            "stub error must point at the token env var; got: ${ex.message}"
        }
    }

    @Test
    fun mapboxConfigDefaultsToHalifaxCamera() {
        val config = MapboxConfig(
            tileTemplateURL = "https://example/tiles/{z}/{x}/{y}.mvt",
            accessToken = "pk.placeholder",
        )
        assertEquals(RoadQualityStyle.DEFAULT_CENTER_LAT, config.initialLat, 0.0)
        assertEquals(RoadQualityStyle.DEFAULT_CENTER_LNG, config.initialLng, 0.0)
        assertEquals(RoadQualityStyle.DEFAULT_ZOOM, config.initialZoom, 0.0)
    }

    /** Mockless `Context` placeholder — the stub throws before it ever
     *  touches the argument, so we don't need Robolectric in this test. */
    private fun throwingContext(): android.content.Context =
        object : android.content.ContextWrapper(null) {}
}
