import Foundation

public struct PrivacyZone: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double

    public init(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }
}

public enum PrivacyZoneFactory {
    public static func makeZone(
        tappedLatitude: Double,
        tappedLongitude: Double,
        requestedRadiusMeters: Double,
        randomAngleRadians: Double,
        randomDistanceMeters: Double
    ) -> PrivacyZone {
        let snapped = snapToGrid(latitude: tappedLatitude, longitude: tappedLongitude, gridSizeMeters: 100)
        let offsetDistance = min(max(randomDistanceMeters, 50), 100)
        let offset = offsetCoordinate(
            latitude: snapped.latitude,
            longitude: snapped.longitude,
            angleRadians: randomAngleRadians,
            distanceMeters: offsetDistance
        )

        return PrivacyZone(
            latitude: offset.latitude,
            longitude: offset.longitude,
            radiusMeters: max(requestedRadiusMeters, 250)
        )
    }

    public static func distanceMeters(
        fromLatitude: Double,
        fromLongitude: Double,
        toLatitude: Double,
        toLongitude: Double
    ) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = fromLatitude * .pi / 180
        let lat2 = toLatitude * .pi / 180
        let deltaLat = (toLatitude - fromLatitude) * .pi / 180
        let deltaLon = (toLongitude - fromLongitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMeters * c
    }

    public static func boundaryCoordinates(
        centerLatitude: Double,
        centerLongitude: Double,
        radiusMeters: Double,
        vertices: Int = 48
    ) -> [(latitude: Double, longitude: Double)] {
        let resolvedVertices = max(vertices, 8)
        let resolvedRadius = max(radiusMeters, 1)

        let ring = (0..<resolvedVertices).map { index in
            let progress = Double(index) / Double(resolvedVertices)
            let angle = progress * 2 * Double.pi
            return offsetCoordinate(
                latitude: centerLatitude,
                longitude: centerLongitude,
                angleRadians: angle,
                distanceMeters: resolvedRadius
            )
        }

        guard let first = ring.first else {
            return []
        }

        return ring + [first]
    }

    private static func snapToGrid(
        latitude: Double,
        longitude: Double,
        gridSizeMeters: Double
    ) -> (latitude: Double, longitude: Double) {
        let latitudeMeters = latitude * 111_320.0
        let longitudeMeters = longitude * 111_320.0 * cos(latitude * .pi / 180)

        let snappedLatitudeMeters = (latitudeMeters / gridSizeMeters).rounded() * gridSizeMeters
        let snappedLongitudeMeters = (longitudeMeters / gridSizeMeters).rounded() * gridSizeMeters

        let snappedLatitude = snappedLatitudeMeters / 111_320.0
        let snappedLongitude = snappedLongitudeMeters / (111_320.0 * cos(latitude * .pi / 180))

        return (snappedLatitude, snappedLongitude)
    }

    private static func offsetCoordinate(
        latitude: Double,
        longitude: Double,
        angleRadians: Double,
        distanceMeters: Double
    ) -> (latitude: Double, longitude: Double) {
        let latitudeOffset = cos(angleRadians) * distanceMeters / 111_320.0
        let longitudeOffset = sin(angleRadians) * distanceMeters / (111_320.0 * cos(latitude * .pi / 180))

        return (
            latitude + latitudeOffset,
            longitude + longitudeOffset
        )
    }
}

public enum PrivacyZoneFilter {
    public static func shouldDrop(_ sample: LocationSample, zones: [PrivacyZone]) -> Bool {
        zones.contains { zone in
            PrivacyZoneFactory.distanceMeters(
                fromLatitude: sample.latitude,
                fromLongitude: sample.longitude,
                toLatitude: zone.latitude,
                toLongitude: zone.longitude
            ) < zone.radiusMeters
        }
    }
}
