import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct SensorCheckpointTests {
    @Test
    func roundTripsCheckpointPayload() throws {
        var builder = ReadingBuilder()
        builder.addMotionSample(
            MotionSample(
                timestamp: 1,
                userAcceleration: MotionVector3(x: 0, y: 0, z: 1),
                gravity: MotionVector3(x: 0, y: 0, z: 1)
            )
        )
        _ = builder.addLocationSample(
            LocationSample(
                timestamp: 1,
                latitude: 44.64,
                longitude: -63.57,
                horizontalAccuracyMeters: 5,
                speedKmh: 40,
                headingDegrees: 90
            )
        )

        var detector = PotholeDetector()
        _ = detector.ingest(
            verticalAccelerationG: -0.8,
            currentLocation: LocationSample(
                timestamp: 1,
                latitude: 44.64,
                longitude: -63.57,
                horizontalAccuracyMeters: 5,
                speedKmh: 40,
                headingDegrees: 90
            )
        )

        let checkpoint = SensorCheckpoint(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            wasCollecting: true,
            latestLocation: LocationSample(
                timestamp: 2,
                latitude: 44.65,
                longitude: -63.58,
                horizontalAccuracyMeters: 4,
                speedKmh: 45,
                headingDegrees: 91
            ),
            recentPotholes: [],
            readingBuilder: builder.snapshot(),
            potholeDetector: detector.snapshot()
        )

        let encoded = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(SensorCheckpoint.self, from: encoded)

        #expect(decoded == checkpoint)
    }

    @Test
    func freshnessExpiresOldCheckpoint() {
        let checkpoint = SensorCheckpoint(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            wasCollecting: true,
            latestLocation: nil,
            recentPotholes: [],
            readingBuilder: ReadingBuilder().snapshot(),
            potholeDetector: PotholeDetector().snapshot()
        )

        #expect(checkpoint.isFresh(at: Date(timeIntervalSince1970: 1_700_000_100), maxAge: 300))
        #expect(!checkpoint.isFresh(at: Date(timeIntervalSince1970: 1_700_002_000), maxAge: 300))
    }
}
