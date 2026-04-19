import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Privacy zones")
struct PrivacyZoneTests {
    @Test("factory snaps to grid, offsets the center, and enforces minimum radius")
    func factoryAppliesPrivacyPreservingTransform() {
        let zone = PrivacyZoneFactory.makeZone(
            tappedLatitude: 44.6488,
            tappedLongitude: -63.5752,
            requestedRadiusMeters: 100,
            randomAngleRadians: .pi / 2,
            randomDistanceMeters: 80
        )

        #expect(zone.radiusMeters == 250)
        #expect(zone.latitude != 44.6488)
        #expect(zone.longitude != -63.5752)
        let displacement = PrivacyZoneFactory.distanceMeters(
            fromLatitude: 44.6488,
            fromLongitude: -63.5752,
            toLatitude: zone.latitude,
            toLongitude: zone.longitude
        )

        #expect(displacement >= 50)
        #expect(displacement <= 150)
    }

    @Test("filter drops locations inside any zone")
    func filterDropsInsideZone() {
        let zone = PrivacyZone(latitude: 44.6488, longitude: -63.5752, radiusMeters: 250)
        let sample = LocationSample(
            timestamp: 0,
            latitude: 44.6490,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 20,
            headingDegrees: 0
        )

        #expect(PrivacyZoneFilter.shouldDrop(sample, zones: [zone]))
    }

    @Test("filter keeps locations outside all zones")
    func filterKeepsOutsideZone() {
        let zone = PrivacyZone(latitude: 44.6488, longitude: -63.5752, radiusMeters: 250)
        let sample = LocationSample(
            timestamp: 0,
            latitude: 44.6600,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 20,
            headingDegrees: 0
        )

        #expect(PrivacyZoneFilter.shouldDrop(sample, zones: [zone]) == false)
    }

    @Test("boundary coordinates form a closed ring near the requested radius")
    func boundaryCoordinatesApproximateRadius() {
        let center = (latitude: 44.6488, longitude: -63.5752)
        let coordinates = PrivacyZoneFactory.boundaryCoordinates(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            radiusMeters: 300,
            vertices: 24
        )

        #expect(coordinates.count == 25)

        let first = coordinates[0]
        let last = coordinates[coordinates.count - 1]
        #expect(first.latitude.isApproximately(equalTo: last.latitude, tolerance: 0.000001))
        #expect(first.longitude.isApproximately(equalTo: last.longitude, tolerance: 0.000001))

        for coordinate in coordinates.dropLast() {
            let distance = PrivacyZoneFactory.distanceMeters(
                fromLatitude: center.latitude,
                fromLongitude: center.longitude,
                toLatitude: coordinate.latitude,
                toLongitude: coordinate.longitude
            )
            #expect(distance.isApproximately(equalTo: 300, tolerance: 12))
        }
    }
}

private extension Double {
    func isApproximately(equalTo other: Double, tolerance: Double) -> Bool {
        abs(self - other) <= tolerance
    }
}
