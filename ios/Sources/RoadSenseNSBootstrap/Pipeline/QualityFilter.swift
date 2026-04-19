import Foundation

public enum ThermalCollectionState: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct DeviceCollectionState: Equatable, Sendable {
    public let thermalState: ThermalCollectionState
    public let isLowPowerModeEnabled: Bool

    public init(
        thermalState: ThermalCollectionState,
        isLowPowerModeEnabled: Bool
    ) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

public enum QualityRejectionReason: Equatable, Sendable {
    case gpsAccuracy
    case speed
    case sampleCount
    case duration
    case thermal
}

public enum QualityFilterDecision: Equatable, Sendable {
    case accepted
    case rejected(QualityRejectionReason)
}

public enum QualityFilter {
    public static func evaluate(
        reading: ReadingWindow,
        deviceState: DeviceCollectionState
    ) -> QualityFilterDecision {
        if reading.gpsAccuracyMeters > 20 {
            return .rejected(.gpsAccuracy)
        }

        if reading.speedKmh < 15 || reading.speedKmh > 160 {
            return .rejected(.speed)
        }

        if reading.sampleCount < 30 {
            return .rejected(.sampleCount)
        }

        if reading.durationSeconds > 15 {
            return .rejected(.duration)
        }

        if deviceState.thermalState == .serious || deviceState.thermalState == .critical {
            return .rejected(.thermal)
        }

        return .accepted
    }
}
