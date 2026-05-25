package ca.roadsense.ns.api

import org.junit.jupiter.api.Test
import java.util.UUID
import kotlin.test.assertEquals

/**
 * Mirrors `ios/Tests/RoadSenseNSBootstrapTests/EndpointsTests.swift` so the
 * two clients build their URLs the same way. The tile template URL in
 * particular drives the Mapbox `VectorSource` configuration on both
 * platforms; drift here would silently break Android map rendering even
 * when the Mapbox SDK itself reports `style loaded`.
 */
class EndpointsTest {

    private val config = AppConfig(
        environment = AppEnvironment.LOCAL,
        apiBaseURL = "http://127.0.0.1:54321",
        mapboxAccessToken = "pk.test-token",
        supabaseAnonKey = "anon.test-key",
    )

    @Test
    fun buildsUploadAndTileURLsFromConfigurableBase() {
        val endpoints = Endpoints(config)
        val segmentID = UUID.fromString("12345678-90ab-cdef-1234-567890abcdef")

        assertEquals(
            "http://127.0.0.1:54321/functions/v1/upload-readings",
            endpoints.uploadReadingsURL,
        )
        assertEquals(
            "http://127.0.0.1:54321/functions/v1/pothole-actions",
            endpoints.potholeActionsURL,
        )
        assertEquals(
            "http://127.0.0.1:54321/functions/v1/feedback",
            endpoints.feedbackURL,
        )
        assertEquals(
            "http://127.0.0.1:54321/functions/v1/segments/12345678-90ab-cdef-1234-567890abcdef",
            endpoints.segmentDetailURL(segmentID),
        )
        assertEquals(
            "http://127.0.0.1:54321/functions/v1/tiles/{z}/{x}/{y}.mvt?apikey=anon.test-key",
            endpoints.tileTemplateURLString,
        )
        assertEquals(
            "http://127.0.0.1:54321/functions/v1/tiles/14/5299/5915.mvt",
            endpoints.tileURL(14, 5299, 5915),
        )
        assertEquals(
            "http://127.0.0.1:54321/functions/v1/tiles/14/5299/5915.mvt?v=197",
            endpoints.tileURL(14, 5299, 5915, version = 197),
        )
    }

    @Test
    fun urlEncodesSupabaseAnonKeyInTileTemplate() {
        // If the anon key ever contains a `+` (base64-url-style) or any
        // other char that must be percent-encoded inside a query string,
        // the template must encode it — otherwise Mapbox will issue
        // requests with broken auth and silently get back 401s.
        val configWithSpecial = config.copy(supabaseAnonKey = "anon+key/with=specials")
        val endpoints = Endpoints(configWithSpecial)
        val template = endpoints.tileTemplateURLString
        assert(!template.contains("anon+key/with=specials")) {
            "tile template URL did not URL-encode the supabase anon key: $template"
        }
        assert(template.contains("anon%2Bkey%2Fwith%3Dspecials")) {
            "tile template URL produced an unexpected encoding: $template"
        }
    }
}
