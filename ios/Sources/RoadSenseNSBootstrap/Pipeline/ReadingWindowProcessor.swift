import Foundation

public struct PersistedReadingCandidate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let roughnessRMS: Double
    public let speedKmh: Double
    public let headingDegrees: Double
    public let gpsAccuracyMeters: Double
    public let isPothole: Bool
    public let potholeMagnitudeG: Double?
    public let recordedAt: Date
    public let durationSeconds: TimeInterval

    public init(
        latitude: Double,
        longitude: Double,
        roughnessRMS: Double,
        speedKmh: Double,
        headingDegrees: Double,
        gpsAccuracyMeters: Double,
        isPothole: Bool,
        potholeMagnitudeG: Double?,
        recordedAt: Date,
        durationSeconds: TimeInterval
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.roughnessRMS = roughnessRMS
        self.speedKmh = speedKmh
        self.headingDegrees = headingDegrees
        self.gpsAccuracyMeters = gpsAccuracyMeters
        self.isPothole = isPothole
        self.potholeMagnitudeG = potholeMagnitudeG
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
    }
}

public enum ReadingWindowProcessingOutcome: Equatable, Sendable {
    case accepted(PersistedReadingCandidate)
    case rejected(QualityRejectionReason)
}

public enum ReadingWindowProcessor {
    public static func process(
        window: ReadingWindow,
        deviceState: DeviceCollectionState,
        potholeCandidates: [PotholeCandidate]
    ) -> ReadingWindowProcessingOutcome {
        switch QualityFilter.evaluate(reading: window, deviceState: deviceState) {
        case .accepted:
            return .accepted(
                PersistedReadingCandidate(
                    latitude: window.latitude,
                    longitude: window.longitude,
                    roughnessRMS: window.roughnessRMS,
                    speedKmh: window.speedKmh,
                    headingDegrees: window.headingDegrees,
                    gpsAccuracyMeters: window.gpsAccuracyMeters,
                    isPothole: !potholeCandidates.isEmpty,
                    potholeMagnitudeG: potholeCandidates.map(\.magnitudeG).max(),
                    recordedAt: Date(timeIntervalSince1970: window.startedAt + window.durationSeconds),
                    durationSeconds: window.durationSeconds
                )
            )
        case let .rejected(reason):
            return .rejected(reason)
        }
    }
}
