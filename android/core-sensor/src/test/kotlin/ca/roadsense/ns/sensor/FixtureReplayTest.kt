package ca.roadsense.ns.sensor

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Replays each CSV fixture and asserts the same envelope iOS asserts. The
 * `*.expected.json` files are the cross-platform parity contract — if this
 * test fails after a sensor change, do not ship until both platforms agree.
 * See docs/implementation/12-android-implementation.md hard-stop rules.
 */
class FixtureReplayTest {
    @Test
    fun `pothole-hit fixture matches committed envelope`() {
        runFixture("pothole-hit")
    }

    @Test
    fun `smooth-cruise fixture matches committed envelope`() {
        runFixture("smooth-cruise")
    }

    @Test
    fun `privacy-zone-recovery fixture matches committed envelope`() {
        runFixture("privacy-zone-recovery")
    }

    @Test
    fun `thermal-reject fixture matches committed envelope`() {
        runFixture("thermal-reject")
    }

    private fun runFixture(name: String) {
        val csv = readResource("/$name.csv")
        val expectedJson = readResource("/$name.expected.json")
        val expected = Json.parseToJsonElement(expectedJson).jsonObject

        val fixture = SensorFixtureParser.parse(csv)
        val zones = expected["privacy_zone"]
            ?.takeUnless { it is JsonNull }
            ?.jsonObject
            ?.let { obj ->
                listOf(
                    PrivacyZone(
                        latitude = obj.getValue("latitude").jsonPrimitive.double,
                        longitude = obj.getValue("longitude").jsonPrimitive.double,
                        radiusMeters = obj.getValue("radius_meters").jsonPrimitive.double,
                    )
                )
            } ?: emptyList()

        val result = SensorFixtureRunner.replay(fixture, zones)

        val expectedWindows = expected.getValue("expected_windows").jsonPrimitive.int
        assertEquals(expectedWindows, result.emittedReadings.size, "$name: emittedReadings.size")

        val expectedFlagged = expected.getValue("expected_pothole_flagged").jsonPrimitive.boolean
        val anyFlagged = result.emittedReadings.any { it.isPothole }
        assertEquals(expectedFlagged, anyFlagged, "$name: pothole_flagged")

        val rmsRange = expected.optDoubleArray("expected_rms_range")
        if (rmsRange != null) {
            val (lo, hi) = rmsRange
            val reading = result.emittedReadings.firstOrNull()
                ?: fail("$name: expected at least one reading for rms range check")
            assertTrue(
                reading.roughnessRMS in lo..hi,
                "$name: roughnessRMS=${reading.roughnessRMS} not in [$lo, $hi]",
            )
        } else {
            assertTrue(
                result.emittedReadings.isEmpty(),
                "$name: expected no readings when rms_range is null, got ${result.emittedReadings.size}",
            )
        }

        val spikeRange = expected.optDoubleArray("expected_max_spike_g_range")
        if (spikeRange != null) {
            val (lo, hi) = spikeRange
            val maxG = result.maxPotholeMagnitudeG ?: 0.0
            assertTrue(
                maxG in lo..hi,
                "$name: maxPotholeMagnitudeG=$maxG not in [$lo, $hi]",
            )
        } else {
            assertEquals(
                null,
                result.maxPotholeMagnitudeG,
                "$name: expected null maxPotholeMagnitudeG when spike_range is null",
            )
        }

        expected.optInt("expected_privacy_filtered_count")?.let { expectedCount ->
            assertEquals(expectedCount, result.privacyFilteredCount, "$name: privacy_filtered_count")
        }

        expected.optInt("expected_rejected_count")?.let { expectedCount ->
            assertEquals(expectedCount, result.rejectedCount, "$name: rejected_count")
        }
    }

    private fun readResource(path: String): String {
        val url = FixtureReplayTest::class.java.getResource(path)
        assertNotNull(url, "missing resource $path")
        return url.readText()
    }

    private fun JsonObject.optInt(key: String): Int? {
        val element = this[key] ?: return null
        if (element is JsonNull) return null
        return (element as? JsonPrimitive)?.let { runCatching { it.int }.getOrNull() }
    }

    private fun JsonObject.optDoubleArray(key: String): Pair<Double, Double>? {
        val element = this[key] ?: return null
        if (element is JsonNull) return null
        val array = element as? JsonArray ?: return null
        if (array.size != 2) return null
        val lo = (array[0] as? JsonPrimitive)?.let { runCatching { it.double }.getOrNull() } ?: return null
        val hi = (array[1] as? JsonPrimitive)?.let { runCatching { it.double }.getOrNull() } ?: return null
        return lo to hi
    }
}
