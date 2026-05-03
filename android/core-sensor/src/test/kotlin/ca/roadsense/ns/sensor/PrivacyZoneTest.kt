package ca.roadsense.ns.sensor

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PrivacyZoneTest {
    @Test
    fun `point inside radius is dropped`() {
        val zone = PrivacyZone(latitude = 44.65, longitude = -63.57, radiusMeters = 250.0)
        val sample = LocationSample(
            timestamp = 0.0,
            latitude = 44.6502,
            longitude = -63.5702,
            horizontalAccuracyMeters = 5.0,
            speedKmh = 50.0,
            headingDegrees = 90.0,
        )
        assertTrue(PrivacyZoneFilter.shouldDrop(sample, listOf(zone)))
    }

    @Test
    fun `point well outside radius is kept`() {
        val zone = PrivacyZone(latitude = 44.65, longitude = -63.57, radiusMeters = 250.0)
        val sample = LocationSample(
            timestamp = 0.0,
            latitude = 44.66,
            longitude = -63.58,
            horizontalAccuracyMeters = 5.0,
            speedKmh = 50.0,
            headingDegrees = 90.0,
        )
        assertFalse(PrivacyZoneFilter.shouldDrop(sample, listOf(zone)))
    }

    @Test
    fun `empty zone list never drops`() {
        val sample = LocationSample(
            timestamp = 0.0,
            latitude = 44.65,
            longitude = -63.57,
            horizontalAccuracyMeters = 5.0,
            speedKmh = 50.0,
            headingDegrees = 90.0,
        )
        assertFalse(PrivacyZoneFilter.shouldDrop(sample, emptyList()))
    }
}
