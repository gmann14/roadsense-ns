import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct ReadingWindowProcessorTests {
    @Test
    func acceptsWindowAndCarriesPotholeMetadata() {
        let window = ReadingWindow(
            latitude: 44.6488,
            longitude: -63.5752,
            roughnessRMS: 0.82,
            speedKmh: 54,
            headingDegrees: 90,
            gpsAccuracyMeters: 5,
            startedAt: 1_700_000_000,
            durationSeconds: 4,
            sampleCount: 200,
            potholeSpikeCount: 0,
            potholeMaxG: 0
        )

        let outcome = ReadingWindowProcessor.process(
            window: window,
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false),
            potholeCandidates: [
                PotholeCandidate(latitude: 44.6488, longitude: -63.5752, magnitudeG: 2.4, timestamp: 1_700_000_002)
            ]
        )

        guard case let .accepted(candidate) = outcome else {
            Issue.record("Expected accepted outcome")
            return
        }

        #expect(candidate.isPothole)
        #expect(candidate.potholeMagnitudeG == 2.4)
        #expect(candidate.recordedAt == Date(timeIntervalSince1970: 1_700_000_004))
        #expect(candidate.durationSeconds == 4)
    }

    @Test
    func rejectsWindowWhenQualityFilterRejects() {
        let window = ReadingWindow(
            latitude: 44.6488,
            longitude: -63.5752,
            roughnessRMS: 0.82,
            speedKmh: 8,
            headingDegrees: 90,
            gpsAccuracyMeters: 5,
            startedAt: 1_700_000_000,
            durationSeconds: 4,
            sampleCount: 200,
            potholeSpikeCount: 0,
            potholeMaxG: 0
        )

        let outcome = ReadingWindowProcessor.process(
            window: window,
            deviceState: DeviceCollectionState(thermalState: .nominal, isLowPowerModeEnabled: false),
            potholeCandidates: []
        )

        #expect(outcome == .rejected(.speed))
    }
}
