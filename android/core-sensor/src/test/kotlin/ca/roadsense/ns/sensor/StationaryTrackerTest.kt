package ca.roadsense.ns.sensor

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StationaryTrackerTest {
    private fun fix(t: Double, lat: Double, speedKmh: Double, accuracy: Double = 5.0) =
        LocationSample(t, lat, -63.5752, accuracy, speedKmh, 0.0)

    @Test
    fun `never auto-ends before any movement is seen`() {
        val tracker = StationaryTracker()
        tracker.observe(fix(0.0, 44.6488, 0.0))
        assertFalse(tracker.shouldAutoEnd(10_000.0))
    }

    @Test
    fun `auto-ends after five stationary minutes even when no fixes arrive`() {
        val tracker = StationaryTracker()
        assertTrue(tracker.observe(fix(0.0, 44.6488, 50.0)))
        assertFalse(tracker.shouldAutoEnd(299.0))
        assertTrue(tracker.shouldAutoEnd(300.0))
    }

    @Test
    fun `gps jitter while parked does not count as movement`() {
        val tracker = StationaryTracker()
        tracker.observe(fix(0.0, 44.6488, 40.0))
        // Parked: ~10 m wobble, sub-walking speeds.
        for (i in 1..60) {
            val lat = 44.6488 + if (i % 2 == 0) 0.00009 else -0.00009
            assertFalse(tracker.observe(fix(i * 10.0, lat, 1.5)))
        }
        assertTrue(tracker.shouldAutoEnd(600.0))
    }

    @Test
    fun `slow creep beyond the radius counts as movement`() {
        val tracker = StationaryTracker()
        tracker.observe(fix(0.0, 44.6488, 30.0))
        // 60 m north at 3 km/h (below the speed floor).
        assertTrue(tracker.observe(fix(70.0, 44.6488 + 0.00054, 3.0)))
        assertFalse(tracker.shouldAutoEnd(300.0))
    }

    @Test
    fun `inaccurate fixes are ignored`() {
        val tracker = StationaryTracker()
        tracker.observe(fix(0.0, 44.6488, 30.0))
        assertFalse(tracker.observe(fix(100.0, 44.70, 80.0, accuracy = 65.0)))
        assertTrue(tracker.shouldAutoEnd(300.0))
    }

    @Test
    fun `movement resets the stationary clock`() {
        val tracker = StationaryTracker()
        tracker.observe(fix(0.0, 44.6488, 30.0))
        tracker.observe(fix(280.0, 44.6488, 25.0))
        assertFalse(tracker.shouldAutoEnd(500.0))
        assertTrue(tracker.shouldAutoEnd(580.0))
    }
}
