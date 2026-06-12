package ca.roadsense.ns.sensor

import kotlin.math.PI
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RoughnessScorerTest {
    @Test
    fun `score is zero for empty input`() {
        assertEquals(0.0, RoughnessScorer().scoreVerticalAccelerations(emptyList()))
    }

    @Test
    fun `dc signal scores well below the 1 Hz signal after high-pass settling`() {
        // The Butterworth biquad has finite settling time, so a constant input
        // never produces exactly 0. The contract: it should be at least an
        // order of magnitude smaller than a same-amplitude in-band sine wave.
        val score = RoughnessScorer().scoreVerticalAccelerations(List(500) { 1.0 })
        assertTrue(score < 0.05, "DC residual should be << in-band signals, got $score")
    }

    @Test
    fun `1 Hz sinusoid scores higher than DC`() {
        val sampleRateHz = 50.0
        val signal = List(500) { sin(2 * PI * 1.0 * it / sampleRateHz) }
        val score = RoughnessScorer(sampleRateHz = sampleRateHz, cutoffHz = 0.5)
            .scoreVerticalAccelerations(signal)
        assertTrue(score > 0.5, "1 Hz signal should pass 0.5 Hz cutoff, got $score")
    }
}
