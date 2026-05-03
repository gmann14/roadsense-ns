package ca.roadsense.ns.sensor

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertTrue

class HighPassBiquadTest {
    @Test
    fun `dc input decays to near-zero output`() {
        val filter = HighPassBiquad.makeButterworth(sampleRateHz = 50.0, cutoffHz = 0.5)
        var last = 0.0
        repeat(500) { last = filter.apply(1.0) }
        assertTrue(abs(last) < 1e-3, "expected near-zero, got $last")
    }

    @Test
    fun `step transient produces decaying response`() {
        val filter = HighPassBiquad.makeButterworth(sampleRateHz = 50.0, cutoffHz = 0.5)
        // Settle at zero
        repeat(50) { filter.apply(0.0) }
        val first = filter.apply(1.0)
        var last = first
        repeat(200) { last = filter.apply(1.0) }
        assertTrue(abs(first) > abs(last), "first=$first should be larger than last=$last")
    }
}
