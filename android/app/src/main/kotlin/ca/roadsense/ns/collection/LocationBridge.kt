package ca.roadsense.ns.collection

import ca.roadsense.ns.sensor.LocationSample

/**
 * Adapter from Android `Location` (or any flat coordinate snapshot) to
 * `core-sensor`'s `LocationSample`. Lives in `:app` because it's the
 * platform-edge type; the pipeline never sees Android types directly.
 *
 * Speed conversion: Android `Location.speed` is m/s; we convert to km/h
 * to match the units the iOS pipeline uses end-to-end.
 */
object LocationBridge {
    private const val MS_TO_KMH = 3.6

    fun fromCoordinates(
        timestampEpochSeconds: Double,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        speedMetersPerSecond: Double,
        bearingDegrees: Double,
    ): LocationSample = LocationSample(
        timestamp = timestampEpochSeconds,
        latitude = latitude,
        longitude = longitude,
        horizontalAccuracyMeters = horizontalAccuracyMeters,
        speedKmh = speedMetersPerSecond * MS_TO_KMH,
        headingDegrees = bearingDegrees,
    )
}
