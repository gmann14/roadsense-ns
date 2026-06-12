package ca.roadsense.ns.sensor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class PotholeDetectorTest {
    private val location = LocationSample(
        timestamp = 0.0,
        latitude = 44.65,
        longitude = -63.57,
        horizontalAccuracyMeters = 5.0,
        speedKmh = 50.0,
        headingDegrees = 90.0,
    )

    @Test
    fun `flat signal does not trigger`() {
        val detector = PotholeDetector()
        repeat(100) {
            assertNull(detector.ingest(0.05, location))
        }
    }

    @Test
    fun `spike without preceding dip does not trigger`() {
        val detector = PotholeDetector()
        repeat(20) { detector.ingest(0.0, location) }
        assertNull(detector.ingest(2.0, location))
    }

    @Test
    fun `dip then spike triggers candidate`() {
        val detector = PotholeDetector()
        repeat(20) { detector.ingest(0.0, location) }
        detector.ingest(-0.5, location) // dip below dipThresholdG
        val candidate = detector.ingest(2.0, location)
        assertNotNull(candidate)
        assertEquals(2.0, candidate.magnitudeG)
    }

    @Test
    fun `snapshot round-trips state`() {
        val detector = PotholeDetector()
        repeat(20) { detector.ingest(0.0, location) }
        detector.ingest(-0.5, location)

        val restored = PotholeDetector(detector.snapshot())
        val candidate = restored.ingest(2.0, location)
        assertNotNull(candidate)
    }
}
