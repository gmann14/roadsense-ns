package ca.roadsense.ns

import io.sentry.Breadcrumb
import io.sentry.SentryEvent
import io.sentry.protocol.Message
import io.sentry.protocol.SentryException
import io.sentry.protocol.User
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Locks the defense-in-depth scrub in [SentryBootstrapper.scrub]. Even if we
 * never expect events to carry coordinates or tokens, an instrumented Compose
 * screen or a future Sentry hook could land them there by accident — the
 * scrub turns that into a no-op.
 */
class SentryBootstrapperTest {
    private val token = "3f2b8c1e-9a4d-4c6b-8e2f-1a2b3c4d5e6f"

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

        val scrubbed = SentryBootstrapper.scrub(event)

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
        val scrubbed = SentryBootstrapper.scrub(event)
        assertEquals(1, scrubbed.breadcrumbs!!.size)
    }

    @Test
    fun scrubsExtrasTagsAndContexts() {
        val event = SentryEvent().apply {
            setExtra("device_token", token)
            setExtra("lastFix", "44.648812, -63.575199")
            setExtra("batch_size", 500)
            setTag("deviceToken", token)
            setTag("screen", "map")
            setTag("note", "token $token rejected")
            contexts["drive"] = mutableMapOf<String, Any?>(
                "latitude" to 44.6488,
                "segments" to 3,
                "summary" to "ended at lat=44.6488 lng=-63.5752",
            )
            contexts["location"] = mapOf("lat" to 44.6)
        }

        val scrubbed = SentryBootstrapper.scrub(event)

        assertNull(scrubbed.getExtra("device_token"))
        assertEquals("[coords]", scrubbed.getExtra("lastFix"))
        assertEquals(500, scrubbed.getExtra("batch_size"))
        assertNull(scrubbed.getTag("deviceToken"))
        assertEquals("map", scrubbed.getTag("screen"))
        assertEquals("token [uuid] rejected", scrubbed.getTag("note"))

        @Suppress("UNCHECKED_CAST")
        val drive = scrubbed.contexts["drive"] as Map<String, Any?>
        assertFalse("latitude" in drive)
        assertEquals(3, drive["segments"])
        assertEquals("ended at lat=[redacted] lng=[redacted]", drive["summary"])
        assertFalse(scrubbed.contexts.containsKey("location"))
    }

    @Test
    fun scrubsMessageExceptionsAndDropsUser() {
        val event = SentryEvent().apply {
            message = Message().apply {
                message = "upload failed for $token at 44.648812,-63.575199"
                formatted = "reply to someone@example.test"
            }
            exceptions = listOf(
                SentryException().apply { value = "bad fix latitude: 44.6488" },
            )
            user = User().apply { id = "installation-id"; ipAddress = "10.0.0.1" }
            breadcrumbs = mutableListOf(Breadcrumb("token=$token"))
        }

        val scrubbed = SentryBootstrapper.scrub(event)

        assertEquals("upload failed for [uuid] at [coords]", scrubbed.message!!.message)
        assertEquals("reply to [email]", scrubbed.message!!.formatted)
        assertEquals("bad fix latitude: [redacted]", scrubbed.exceptions!!.first().value)
        assertNull(scrubbed.user)
        assertEquals("token=[uuid]", scrubbed.breadcrumbs!!.first().message)
    }

    @Test
    fun leavesOrdinaryTextAlone() {
        val text = "upload batch failed with HTTP 503 after 3 attempts (v0.1.0)"
        assertEquals(text, SentryBootstrapper.scrubText(text))
    }
}
