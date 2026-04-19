import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Driving heuristic")
struct DrivingHeuristicTests {
    @Test("enters driving after 30 seconds above 15 km/h")
    func entersDrivingAfterSustainedSpeed() {
        var heuristic = DrivingHeuristic()
        var isDriving = false

        for second in 0...30 {
            isDriving = heuristic.ingest(
                sample: LocationSample(
                    timestamp: TimeInterval(second),
                    latitude: 44.6488,
                    longitude: -63.5752,
                    horizontalAccuracyMeters: 5,
                    speedKmh: 20,
                    headingDegrees: 0
                )
            )
        }

        #expect(isDriving)
    }

    @Test("drops out of driving when speed falls below threshold")
    func leavesDrivingWhenSpeedDrops() {
        var heuristic = DrivingHeuristic()

        for second in 0...30 {
            _ = heuristic.ingest(
                sample: LocationSample(
                    timestamp: TimeInterval(second),
                    latitude: 44.6488,
                    longitude: -63.5752,
                    horizontalAccuracyMeters: 5,
                    speedKmh: 20,
                    headingDegrees: 0
                )
            )
        }

        let next = heuristic.ingest(
            sample: LocationSample(
                timestamp: 31,
                latitude: 44.6488,
                longitude: -63.5752,
                horizontalAccuracyMeters: 5,
                speedKmh: 5,
                headingDegrees: 0
            )
        )

        #expect(next == false)
    }
}
