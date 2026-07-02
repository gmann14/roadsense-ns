package ca.roadsense.ns.pothole

import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.PrivacyZoneFilter
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Covers the privacy-critical fix in `AppViewModel.reportPothole`: a manual
 * pothole report must be checked against configured privacy zones with the
 * exact same filter the passive collection pipeline uses
 * (`CollectionPipeline` → `PrivacyZoneFilter.shouldDrop`), so a report tapped
 * at home doesn't upload exact home coordinates just because it bypassed the
 * passive-reading path.
 *
 * This exercises the shared filter with the same LocationSample shape
 * `AppViewModel.reportPothole` builds from `HomeState.lastLocation` (speed
 * and heading are unknown for a manual tap, so they're zeroed — the filter
 * only uses lat/lng/radius, so this doesn't affect the result).
 */
class PotholeReportPrivacyZoneTest {
    private val homeZone = PrivacyZone(latitude = 44.6488, longitude = -63.5752, radiusMeters = 250.0)

    private fun manualReportSample(latitude: Double, longitude: Double) = LocationSample(
        timestamp = 1_000.0,
        latitude = latitude,
        longitude = longitude,
        horizontalAccuracyMeters = 6.0,
        speedKmh = 0.0,
        headingDegrees = 0.0,
    )

    @Test
    fun `report at the exact zone center is blocked`() {
        val sample = manualReportSample(homeZone.latitude, homeZone.longitude)
        assertTrue(PrivacyZoneFilter.shouldDrop(sample, listOf(homeZone)))
    }

    @Test
    fun `report well inside the zone radius is blocked`() {
        // ~100m north of the zone center, radius is 250m.
        val sample = manualReportSample(homeZone.latitude + 0.0009, homeZone.longitude)
        assertTrue(PrivacyZoneFilter.shouldDrop(sample, listOf(homeZone)))
    }

    @Test
    fun `report well outside the zone radius is allowed`() {
        // ~1.1km away — outside the 250m radius.
        val sample = manualReportSample(homeZone.latitude + 0.01, homeZone.longitude)
        assertFalse(PrivacyZoneFilter.shouldDrop(sample, listOf(homeZone)))
    }

    @Test
    fun `report is allowed when no zones are configured`() {
        val sample = manualReportSample(homeZone.latitude, homeZone.longitude)
        assertFalse(PrivacyZoneFilter.shouldDrop(sample, emptyList()))
    }

    @Test
    fun `report is blocked if it falls inside any of multiple configured zones`() {
        val workZone = PrivacyZone(latitude = 44.70, longitude = -63.62, radiusMeters = 200.0)
        val sample = manualReportSample(workZone.latitude, workZone.longitude)
        assertTrue(PrivacyZoneFilter.shouldDrop(sample, listOf(homeZone, workZone)))
    }
}
