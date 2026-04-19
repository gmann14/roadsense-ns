import Foundation

public struct DrivingHeuristic: Sendable {
    public var speedThresholdKmh: Double = 15
    public var sustainDurationSeconds: TimeInterval = 30

    private var aboveThresholdStartedAt: TimeInterval?

    public init() {}

    public mutating func ingest(sample: LocationSample) -> Bool {
        guard sample.speedKmh > speedThresholdKmh else {
            aboveThresholdStartedAt = nil
            return false
        }

        if aboveThresholdStartedAt == nil {
            aboveThresholdStartedAt = sample.timestamp
        }

        guard let start = aboveThresholdStartedAt else {
            return false
        }

        return sample.timestamp - start >= sustainDurationSeconds
    }
}
