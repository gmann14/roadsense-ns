import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Pothole detector")
struct PotholeDetectorTests {
    @Test("emits a pothole candidate when a dip is followed by a strong spike")
    func emitsCandidateForDipThenSpike() {
        var detector = PotholeDetector()
        let location = LocationSample(
            timestamp: 10,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 40,
            headingDegrees: 0
        )

        for _ in 0..<45 {
            #expect(detector.ingest(verticalAccelerationG: 0.1, currentLocation: location) == nil)
        }

        #expect(detector.ingest(verticalAccelerationG: -0.7, currentLocation: location) == nil)
        #expect(detector.ingest(verticalAccelerationG: 2.3, currentLocation: location)?.magnitudeG == 2.3)
    }

    @Test("does not emit for an isolated spike without the preceding dip")
    func ignoresIsolatedSpike() {
        var detector = PotholeDetector()
        let location = LocationSample(
            timestamp: 10,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 40,
            headingDegrees: 0
        )

        for _ in 0..<50 {
            #expect(detector.ingest(verticalAccelerationG: 0.1, currentLocation: location) == nil)
        }

        #expect(detector.ingest(verticalAccelerationG: 2.3, currentLocation: location) == nil)
    }
}
