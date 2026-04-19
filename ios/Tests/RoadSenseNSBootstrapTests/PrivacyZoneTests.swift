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
}

private extension Double {
    func isApproximately(equalTo other: Double, tolerance: Double) -> Bool {
        abs(self - other) <= tolerance
    }
}
