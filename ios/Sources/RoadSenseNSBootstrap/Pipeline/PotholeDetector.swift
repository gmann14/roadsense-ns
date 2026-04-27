import Foundation

public struct PotholeCandidate: Equatable, Sendable, Codable {
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
    public struct Snapshot: Equatable, Sendable, Codable {
        public let spikeThresholdG: Double
        public let dipThresholdG: Double
        public let historyWindowSize: Int
        public let dipLookbackSampleCount: Int
        public let history: [Double]

        public init(
            spikeThresholdG: Double,
            dipThresholdG: Double,
            historyWindowSize: Int,
            dipLookbackSampleCount: Int,
            history: [Double]
        ) {
            self.spikeThresholdG = spikeThresholdG
            self.dipThresholdG = dipThresholdG
            self.historyWindowSize = historyWindowSize
            self.dipLookbackSampleCount = dipLookbackSampleCount
            self.history = history
        }
    }

    // Defaults tuned for typical NS driving in a passenger car: a moderate
    // pothole strike at 50–80 km/h registers ~0.8–1.6G, deep ones 2G+. The
    // dip-then-spike pattern keeps false positives down (smooth speed bumps
    // rise without dipping first).
    public var spikeThresholdG: Double = 1.0
    public var dipThresholdG: Double = -0.3
    public var historyWindowSize: Int = 50
    public var dipLookbackSampleCount: Int = 5

    private var history: [Double] = []

    public init() {}

    public init(snapshot: Snapshot) {
        self.spikeThresholdG = snapshot.spikeThresholdG
        self.dipThresholdG = snapshot.dipThresholdG
        self.historyWindowSize = snapshot.historyWindowSize
        self.dipLookbackSampleCount = snapshot.dipLookbackSampleCount
        self.history = snapshot.history
    }

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

    public func snapshot() -> Snapshot {
        Snapshot(
            spikeThresholdG: spikeThresholdG,
            dipThresholdG: dipThresholdG,
            historyWindowSize: historyWindowSize,
            dipLookbackSampleCount: dipLookbackSampleCount,
            history: history
        )
    }
}
