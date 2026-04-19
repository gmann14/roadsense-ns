import Foundation

public struct SensorFixtureReplayResult: Equatable, Sendable {
    public let emittedReadings: [PersistedReadingCandidate]
    public let privacyFilteredCount: Int
    public let rejectedCount: Int
    public let maxPotholeMagnitudeG: Double?

    public init(
        emittedReadings: [PersistedReadingCandidate],
        privacyFilteredCount: Int,
        rejectedCount: Int,
        maxPotholeMagnitudeG: Double?
    ) {
        self.emittedReadings = emittedReadings
        self.privacyFilteredCount = privacyFilteredCount
        self.rejectedCount = rejectedCount
        self.maxPotholeMagnitudeG = maxPotholeMagnitudeG
    }
}

public struct SensorFixtureExpected: Codable, Equatable, Sendable {
    public let fixture: String
    public let expectedWindows: Int
    public let expectedPotholeFlagged: Bool
    public let expectedRmsRange: [Double]
    public let expectedMaxSpikeGRange: [Double]

    enum CodingKeys: String, CodingKey {
        case fixture
        case expectedWindows = "expected_windows"
        case expectedPotholeFlagged = "expected_pothole_flagged"
        case expectedRmsRange = "expected_rms_range"
        case expectedMaxSpikeGRange = "expected_max_spike_g_range"
    }
}

public enum SensorFixtureRunner {
    public static func replay(
        fixture: SensorFixture,
        privacyZones: [PrivacyZone] = []
    ) -> SensorFixtureReplayResult {
        var readingBuilder = ReadingBuilder()
        var potholeDetector = PotholeDetector()
        var emittedReadings: [PersistedReadingCandidate] = []
        var recentPotholes: [PotholeCandidate] = []
        var latestLocation: LocationSample?
        var latestGravity = MotionVector3(x: 0, y: 0, z: 1)
        var thermalState: ThermalCollectionState = .nominal
        var isAutomotive = false
        var privacyFilteredCount = 0
        var rejectedCount = 0

        for event in fixture.events {
            switch event {
            case let .activity(_, automotive):
                if !automotive {
                    readingBuilder = ReadingBuilder()
                    potholeDetector = PotholeDetector()
                    recentPotholes = []
                    latestLocation = nil
                }
                isAutomotive = automotive

            case let .thermal(_, state):
                thermalState = state

            case let .gravity(_, gravity):
                latestGravity = gravity

            case let .accel(timestamp, userAcceleration):
                guard isAutomotive else {
                    continue
                }

                let motionSample = MotionSample(
                    timestamp: timestamp.timeIntervalSince1970,
                    userAcceleration: userAcceleration,
                    gravity: latestGravity
                )
                readingBuilder.addMotionSample(motionSample)

                if let latestLocation,
                   let pothole = potholeDetector.ingest(
                    verticalAccelerationG: motionSample.verticalAcceleration,
                    currentLocation: latestLocation
                   ) {
                    recentPotholes.append(pothole)
                }

            case let .gps(_, sample):
                guard isAutomotive else {
                    continue
                }

                latestLocation = sample

                if PrivacyZoneFilter.shouldDrop(sample, zones: privacyZones) {
                    privacyFilteredCount += 1
                    readingBuilder = ReadingBuilder()
                    potholeDetector = PotholeDetector()
                    recentPotholes = []
                    continue
                }

                guard let window = readingBuilder.addLocationSample(sample) else {
                    continue
                }

                let windowEnd = window.startedAt + window.durationSeconds
                let potholesInWindow = recentPotholes.filter {
                    $0.timestamp >= window.startedAt && $0.timestamp <= windowEnd
                }

                switch ReadingWindowProcessor.process(
                    window: window,
                    deviceState: DeviceCollectionState(
                        thermalState: thermalState,
                        isLowPowerModeEnabled: false
                    ),
                    potholeCandidates: potholesInWindow
                ) {
                case let .accepted(candidate):
                    emittedReadings.append(candidate)
                case .rejected:
                    rejectedCount += 1
                }

                recentPotholes.removeAll { $0.timestamp <= windowEnd }
            }
        }

        return SensorFixtureReplayResult(
            emittedReadings: emittedReadings,
            privacyFilteredCount: privacyFilteredCount,
            rejectedCount: rejectedCount,
            maxPotholeMagnitudeG: emittedReadings.compactMap(\.potholeMagnitudeG).max()
        )
    }
}
