package ca.roadsense.ns.collection

import org.junit.Test
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LocationBridgeTest {
    @Test
    fun `converts meters per second to km h`() {
        val sample = LocationBridge.fromCoordinates(
            timestampEpochSeconds = 100.0,
            latitude = 44.65,
            longitude = -63.57,
            horizontalAccuracyMeters = 5.0,
            speedMetersPerSecond = 10.0,
            bearingDegrees = 90.0,
        )
        // 10 m/s = 36 km/h
        assertEquals(36.0, sample.speedKmh)
    }

    @Test
    fun `passes through other fields verbatim`() {
        val sample = LocationBridge.fromCoordinates(
            timestampEpochSeconds = 1234.5,
            latitude = 44.6488,
            longitude = -63.5752,
            horizontalAccuracyMeters = 7.25,
            speedMetersPerSecond = 0.0,
            bearingDegrees = 142.5,
        )
        assertEquals(1234.5, sample.timestamp)
        assertEquals(44.6488, sample.latitude)
        assertEquals(-63.5752, sample.longitude)
        assertEquals(7.25, sample.horizontalAccuracyMeters)
        assertEquals(142.5, sample.headingDegrees)
        assertTrue(abs(sample.speedKmh) < 1e-9)
    }
}
