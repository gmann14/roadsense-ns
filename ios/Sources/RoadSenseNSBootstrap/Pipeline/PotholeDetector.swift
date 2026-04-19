import Foundation

public struct PotholeCandidate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let magnitudeG: Double
    public let timestamp: TimeInterval

    public init(
        latitude: Double,
        longitude: Double,
        magnitudeG: Double,
        timestamp: TimeInterval
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.magnitudeG = magnitudeG
        self.timestamp = timestamp
    }
}

public struct PotholeDetector: Sendable {
    public var spikeThresholdG: Double = 2.0
    public var dipThresholdG: Double = -0.5
    public var historyWindowSize: Int = 50
    public var dipLookbackSampleCount: Int = 5

    private var history: [Double] = []

    public init() {}

    public mutating func ingest(
        verticalAccelerationG: Double,
        currentLocation: LocationSample
    ) -> PotholeCandidate? {
        history.append(verticalAccelerationG)

        if history.count > historyWindowSize {
            history.removeFirst(history.count - historyWindowSize)
        }

        guard verticalAccelerationG > spikeThresholdG else {
            return nil
        }

        let lookback = history.dropLast().suffix(dipLookbackSampleCount)
        guard let minRecent = lookback.min(), minRecent < dipThresholdG else {
            return nil
        }

        return PotholeCandidate(
            latitude: currentLocation.latitude,
            longitude: currentLocation.longitude,
            magnitudeG: verticalAccelerationG,
            timestamp: currentLocation.timestamp
        )
    }
}
