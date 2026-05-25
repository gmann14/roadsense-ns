package ca.roadsense.ns.sensor

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round
import kotlin.math.sin
import kotlin.math.sqrt

data class PrivacyZone(
    val latitude: Double,
    val longitude: Double,
    val radiusMeters: Double,
)

object PrivacyZoneFactory {
    fun makeZone(
        tappedLatitude: Double,
        tappedLongitude: Double,
        requestedRadiusMeters: Double,
        randomAngleRadians: Double,
        randomDistanceMeters: Double,
    ): PrivacyZone {
        val snapped = snapToGrid(tappedLatitude, tappedLongitude, gridSizeMeters = 100.0)
        val offsetDistance = min(max(randomDistanceMeters, 50.0), 100.0)
        val offset = offsetCoordinate(
            latitude = snapped.first,
            longitude = snapped.second,
            angleRadians = randomAngleRadians,
            distanceMeters = offsetDistance,
        )
        return PrivacyZone(
            latitude = offset.first,
            longitude = offset.second,
            radiusMeters = max(requestedRadiusMeters, 250.0),
        )
    }

    fun distanceMeters(
        fromLatitude: Double,
        fromLongitude: Double,
        toLatitude: Double,
        toLongitude: Double,
    ): Double {
        val earthRadiusMeters = 6_371_000.0
        val lat1 = fromLatitude * PI / 180
        val lat2 = toLatitude * PI / 180
        val deltaLat = (toLatitude - fromLatitude) * PI / 180
        val deltaLon = (toLongitude - fromLongitude) * PI / 180

        val a = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        val c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }

    fun boundaryCoordinates(
        centerLatitude: Double,
        centerLongitude: Double,
        radiusMeters: Double,
        vertices: Int = 48,
    ): List<Pair<Double, Double>> {
        val resolvedVertices = max(vertices, 8)
        val resolvedRadius = max(radiusMeters, 1.0)

        val ring = (0 until resolvedVertices).map { index ->
            val progress = index.toDouble() / resolvedVertices
            val angle = progress * 2 * PI
            offsetCoordinate(
                latitude = centerLatitude,
                longitude = centerLongitude,
                angleRadians = angle,
                distanceMeters = resolvedRadius,
            )
        }
        return if (ring.isEmpty()) ring else ring + ring.first()
    }

    private fun snapToGrid(
        latitude: Double,
        longitude: Double,
        gridSizeMeters: Double,
    ): Pair<Double, Double> {
        val latitudeMeters = latitude * 111_320.0
        val longitudeMeters = longitude * 111_320.0 * cos(latitude * PI / 180)

        val snappedLatitudeMeters = round(latitudeMeters / gridSizeMeters) * gridSizeMeters
        val snappedLongitudeMeters = round(longitudeMeters / gridSizeMeters) * gridSizeMeters

        val snappedLatitude = snappedLatitudeMeters / 111_320.0
        val snappedLongitude = snappedLongitudeMeters / (111_320.0 * cos(latitude * PI / 180))

        return snappedLatitude to snappedLongitude
    }

    private fun offsetCoordinate(
        latitude: Double,
        longitude: Double,
        angleRadians: Double,
        distanceMeters: Double,
    ): Pair<Double, Double> {
        val latitudeOffset = cos(angleRadians) * distanceMeters / 111_320.0
        val longitudeOffset = sin(angleRadians) * distanceMeters / (111_320.0 * cos(latitude * PI / 180))
        return Pair(latitude + latitudeOffset, longitude + longitudeOffset)
    }
}

object PrivacyZoneFilter {
    fun shouldDrop(sample: LocationSample, zones: List<PrivacyZone>): Boolean {
        if (zones.isEmpty()) return false
        for (zone in zones) {
            val distance = PrivacyZoneFactory.distanceMeters(
                fromLatitude = sample.latitude,
                fromLongitude = sample.longitude,
                toLatitude = zone.latitude,
                toLongitude = zone.longitude,
            )
            if (distance < zone.radiusMeters) return true
        }
        return false
    }
}
