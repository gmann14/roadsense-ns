package ca.roadsense.ns.sensor

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DriveEndpointTrimmerTest {
    private val session = DriveSessionEndpoints(
        startedAt = Instant.ofEpochSecond(1_000),
        endedAt = Instant.ofEpochSecond(1_600),
        startLatitude = 44.6488,
        startLongitude = -63.5752,
        endLatitude = 44.7090,
        endLongitude = -63.6220,
    )

    @Test
    fun `trims readings during the first minute`() {
        val shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt = Instant.ofEpochSecond(1_030),
            latitude = 44.6600,
            longitude = -63.5900,
            session = session,
        )

        assertTrue(shouldTrim)
    }

    @Test
    fun `trims readings during the last minute`() {
        val shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt = Instant.ofEpochSecond(1_580),
            latitude = 44.6900,
            longitude = -63.6100,
            session = session,
        )

        assertTrue(shouldTrim)
    }

    @Test
    fun `trims readings near the start coordinate even after the time window`() {
        val shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt = Instant.ofEpochSecond(1_120),
            latitude = 44.6500,
            longitude = -63.5750,
            session = session,
        )

        assertTrue(shouldTrim)
    }

    @Test
    fun `keeps mid-drive readings outside both endpoint zones`() {
        val shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt = Instant.ofEpochSecond(1_300),
            latitude = 44.6800,
            longitude = -63.6000,
            session = session,
        )

        assertFalse(shouldTrim)
    }
}
