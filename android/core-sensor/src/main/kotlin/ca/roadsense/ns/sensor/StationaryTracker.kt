package ca.roadsense.ns.sensor

/**
 * Decides when a recording drive has ended on its own: the car has not moved
 * for [autoEndAfterSeconds]. Without this, "drive to work, park 8 h, drive
 * home" is one session and both workplace endpoints upload untrimmed.
 *
 * A fix counts as movement when it is accurate enough to trust
 * ([maxAccuracyMeters]) and either reports a speed of at least
 * [movingSpeedKmh] or lies [movingRadiusMeters] or more from the last moving
 * fix (the anchor). GPS jitter around a parked car stays inside the radius
 * and below the speed floor.
 *
 * Time comes from the caller, so a parked phone that stops delivering fixes
 * (Android's distance filter suppresses them) is still detected by a periodic
 * [shouldAutoEnd] check.
 */
class StationaryTracker(
    val movingSpeedKmh: Double = 5.0,
    val movingRadiusMeters: Double = 50.0,
    val maxAccuracyMeters: Double = 20.0,
    val autoEndAfterSeconds: Double = 300.0,
) {
    private var anchor: LocationSample? = null

    /** Epoch seconds of the last fix that counted as movement. */
    var lastMovementAt: Double? = null
        private set

    /** Feeds one fix; returns true when it counts as movement. */
    fun observe(sample: LocationSample): Boolean {
        if (sample.horizontalAccuracyMeters > maxAccuracyMeters) return false
        val reference = anchor
        val moving = sample.speedKmh >= movingSpeedKmh ||
            (reference != null && distanceMeters(reference, sample) >= movingRadiusMeters)
        if (moving || reference == null) anchor = sample
        if (moving) lastMovementAt = sample.timestamp
        return moving
    }

    /** True once no movement has been seen for [autoEndAfterSeconds]. False
     *  until movement has been seen at least once. */
    fun shouldAutoEnd(nowEpochSeconds: Double): Boolean {
        val last = lastMovementAt ?: return false
        return nowEpochSeconds - last >= autoEndAfterSeconds
    }

    fun reset() {
        anchor = null
        lastMovementAt = null
    }

    private fun distanceMeters(a: LocationSample, b: LocationSample): Double =
        PrivacyZoneFactory.distanceMeters(
            fromLatitude = a.latitude,
            fromLongitude = a.longitude,
            toLatitude = b.latitude,
            toLongitude = b.longitude,
        )
}
