package ca.roadsense.ns.sensor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * The motion buffer must stay bounded when no GPS fix arrives (a parked phone
 * behind the 5 m distance filter keeps streaming 50 Hz motion all night).
 */
class ReadingBuilderBufferTest {
    private fun motion(t: Double) = MotionSample(
        timestamp = t,
        userAcceleration = MotionVector3(0.0, 0.0, 0.01),
        gravity = MotionVector3(0.0, 0.0, 1.0),
    )

    @Test
    fun `motion buffer is capped at 2000 samples and drops the oldest`() {
        val builder = ReadingBuilder()
        // One hour at 50 Hz with no location samples.
        repeat(180_000) { builder.addMotionSample(motion(it / 50.0)) }

        assertEquals(2_000, builder.bufferedMotionSampleCount)
        val snapshot = builder.snapshot()
        assertEquals((180_000 - 2_000) / 50.0, snapshot.motionSamples.first().timestamp)
        assertEquals(179_999 / 50.0, snapshot.motionSamples.last().timestamp)
    }

    @Test
    fun `restoring an oversized snapshot is trimmed to the cap`() {
        val oversized = ReadingBuilder.Snapshot(
            targetDistanceMeters = 40.0,
            maxDurationSeconds = 15.0,
            maxHorizontalAccuracyMeters = 20.0,
            maxHeadingVarianceDegrees = 60.0,
            minimumSampleCount = 30,
            locationSamples = emptyList(),
            motionSamples = List(5_000) { motion(it / 50.0) },
        )
        assertEquals(2_000, ReadingBuilder(oversized).bufferedMotionSampleCount)
    }

    @Test
    fun `cap does not affect a normal window`() {
        val builder = ReadingBuilder()
        val start = 1_000.0
        // ~3 s of 50 Hz motion between three fixes ~22 m apart.
        builder.addLocationSample(LocationSample(start, 44.6488, -63.5752, 5.0, 54.0, 0.0))
        repeat(150) { builder.addMotionSample(motion(start + it / 50.0)) }
        builder.addLocationSample(LocationSample(start + 2, 44.64900, -63.5752, 5.0, 54.0, 0.0))
        val window = builder.addLocationSample(LocationSample(start + 3, 44.64920, -63.5752, 5.0, 54.0, 0.0))
        assertNotNull(window)
        assertEquals(150, window.sampleCount)
    }
}
