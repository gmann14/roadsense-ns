package ca.roadsense.ns.sensor

import java.time.Instant

/**
 * Mirror of iOS `DriveSessionEndpoints`. Snapshot of the start/end of a drive
 * used to decide whether a reading falls inside the endpoint-trim window.
 */
data class DriveSessionEndpoints(
    val startedAt: Instant,
    val endedAt: Instant,
    val startLatitude: Double,
    val startLongitude: Double,
    val endLatitude: Double,
    val endLongitude: Double,
)

/**
 * Mirror of iOS `DriveEndpointTrimmer`. Hides the first/last minute and the
 * area within 300m of the drive's start/end coordinates so home/work
 * addresses never leave the device — even when the user hasn't configured an
 * explicit privacy zone. Applied on every drive regardless of privacy-zone
 * setup.
 */
object DriveEndpointTrimmer {
    const val TRIM_WINDOW_SECONDS: Long = 60
    const val TRIM_RADIUS_METERS: Double = 300.0

    fun shouldTrim(
        readingRecordedAt: Instant,
        latitude: Double,
        longitude: Double,
        session: DriveSessionEndpoints,
    ): Boolean {
        if (readingRecordedAt < session.startedAt.plusSeconds(TRIM_WINDOW_SECONDS)) {
            return true
        }

        if (readingRecordedAt > session.endedAt.minusSeconds(TRIM_WINDOW_SECONDS)) {
            return true
        }

        val distanceFromStart = PrivacyZoneFactory.distanceMeters(
            fromLatitude = latitude,
            fromLongitude = longitude,
            toLatitude = session.startLatitude,
            toLongitude = session.startLongitude,
        )
        if (distanceFromStart < TRIM_RADIUS_METERS) return true

        val distanceFromEnd = PrivacyZoneFactory.distanceMeters(
            fromLatitude = latitude,
            fromLongitude = longitude,
            toLatitude = session.endLatitude,
            toLongitude = session.endLongitude,
        )
        if (distanceFromEnd < TRIM_RADIUS_METERS) return true

        return false
    }
}
