import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Pothole detector")
struct PotholeDetectorTests {
    private static func location() -> LocationSample {
        LocationSample(
            timestamp: 10,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 40,
            headingDegrees: 0
        )
    }

    @Test("emits a pothole candidate when a dip is followed by a strong spike")
    func emitsCandidateForDipThenSpike() {
        var detector = PotholeDetector()
        let loc = Self.location()

        for _ in 0..<45 {
            #expect(detector.ingest(verticalAccelerationG: 0.1, currentLocation: loc) == nil)
        }

        #expect(detector.ingest(verticalAccelerationG: -0.7, currentLocation: loc) == nil)
        #expect(detector.ingest(verticalAccelerationG: 2.3, currentLocation: loc)?.magnitudeG == 2.3)
    }

    @Test("emits a candidate for a moderate hit (1.2G after a -0.4G dip)")
    func emitsCandidateForModerateHit() {
        // Reflects what a typical NS pothole strike at 60 km/h looks like
        // (peak ~1-1.5G with a brief precursor dip). The pre-tuning 2.0G
        // default would have missed this entirely.
        var detector = PotholeDetector()
        let loc = Self.location()

        for _ in 0..<45 {
            #expect(detector.ingest(verticalAccelerationG: 0.1, currentLocation: loc) == nil)
        }

        #expect(detector.ingest(verticalAccelerationG: -0.4, currentLocation: loc) == nil)
        let candidate = detector.ingest(verticalAccelerationG: 1.2, currentLocation: loc)
        #expect(candidate?.magnitudeG == 1.2)
    }

    @Test("ignores spikes that fall just under the threshold")
    func ignoresSpikeBelowThreshold() {
        var detector = PotholeDetector()
        let loc = Self.location()

        for _ in 0..<45 {
            _ = detector.ingest(verticalAccelerationG: 0.1, currentLocation: loc)
        }

        _ = detector.ingest(verticalAccelerationG: -0.5, currentLocation: loc)
        // Just under the 1.0G threshold — must not fire.
        #expect(detector.ingest(verticalAccelerationG: 0.95, currentLocation: loc) == nil)
    }

    @Test("does not emit for an isolated spike without the preceding dip")
    func ignoresIsolatedSpike() {
        var detector = PotholeDetector()
        let loc = Self.location()

        for _ in 0..<50 {
            #expect(detector.ingest(verticalAccelerationG: 0.1, currentLocation: loc) == nil)
        }

        #expect(detector.ingest(verticalAccelerationG: 2.3, currentLocation: loc) == nil)
    }

    @Test("ignores a smooth speed-bump-shaped event (rise without preceding dip)")
    func ignoresSmoothSpeedBump() {
        var detector = PotholeDetector()
        let loc = Self.location()

        for _ in 0..<45 {
            _ = detector.ingest(verticalAccelerationG: 0.1, currentLocation: loc)
        }

        // Speed bump profile: gradual rise to 1.4G with no dip below threshold.
        for value in [0.2, 0.4, 0.7, 1.0, 1.4] as [Double] {
            #expect(detector.ingest(verticalAccelerationG: value, currentLocation: loc) == nil)
        }
    }
}
