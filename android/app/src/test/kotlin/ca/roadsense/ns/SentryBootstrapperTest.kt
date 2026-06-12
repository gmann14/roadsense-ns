package ca.roadsense.ns

import io.sentry.Breadcrumb
import io.sentry.SentryEvent
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Locks the defense-in-depth scrub in [SentryBootstrapper.scrubLocationData].
 * Even if we never expect breadcrumbs to carry coordinates, an instrumented
 * Compose screen or a future Sentry breadcrumb hook elsewhere could land
 * `lat`/`lng` in there by accident — the scrub turns that into a no-op.
 */
class SentryBootstrapperTest {

    @Test
    fun stripsKnownLocationKeysFromBreadcrumbData() {
        val event = SentryEvent().apply {
            breadcrumbs = mutableListOf(
                Breadcrumb("drove past privacy zone").apply {
                    setData("lat", 44.6488)
                    setData("lng", -63.5752)
                    setData("accuracy_m", 5.0)
                    setData("speed_kmh", 47.3)
                },
                Breadcrumb("upload result").apply {
                    setData("latitude", 44.6)
                    setData("longitude", -63.5)
                    setData("accuracyMeters", 6.2)
                    setData("accepted", 18)
                    setData("rejected", 1)
                },
            )
        }

        val scrubbed = SentryBootstrapper.scrubLocationData(event)

        val first = scrubbed.breadcrumbs!![0].data!!
        assertFalse("lat" in first, "lat must be scrubbed")
        assertFalse("lng" in first, "lng must be scrubbed")
        assertFalse("accuracy_m" in first, "accuracy_m must be scrubbed")
        assertTrue("speed_kmh" in first, "non-location keys must survive")
        assertEquals(47.3, first["speed_kmh"])

        val second = scrubbed.breadcrumbs!![1].data!!
        assertFalse("latitude" in second)
        assertFalse("longitude" in second)
        assertFalse("accuracyMeters" in second)
        assertTrue("accepted" in second)
        assertTrue("rejected" in second)
    }

    @Test
    fun toleratesBreadcrumbsWithoutData() {
        val event = SentryEvent().apply {
            breadcrumbs = mutableListOf(Breadcrumb("started drive"))
        }
        // The scrub must not throw on null/missing data maps.
        val scrubbed = SentryBootstrapper.scrubLocationData(event)
        assertEquals(1, scrubbed.breadcrumbs!!.size)
    }
}
