import Foundation

public enum ReadingDiagnosticUnit: String, Codable, Sendable, CaseIterable {
    case readingWindow = "reading_window"
    case locationSample = "location_sample"
    case collectionSample = "collection_sample"
}

public enum ReadingDiagnosticReason: String, Codable, Sendable, CaseIterable {
    case collectionNotActive = "collection_not_active"
    case privacyZone = "privacy_zone"
    case builderGpsAccuracy = "builder_gps_accuracy"
    case builderDuration = "builder_duration"
    case builderHeadingVariance = "builder_heading_variance"
    case builderSampleCount = "builder_sample_count"
    case builderPartialAtSeal = "builder_partial_at_seal"
    case qualityGpsAccuracy = "quality_gps_accuracy"
    case qualitySpeed = "quality_speed"
    case qualitySampleCount = "quality_sample_count"
    case qualityDuration = "quality_duration"
    case qualityThermal = "quality_thermal"
    case persistFailure = "persist_failure"

    public var unit: ReadingDiagnosticUnit {
        switch self {
        case .collectionNotActive:
            return .collectionSample
        case .privacyZone:
            return .locationSample
        case .builderGpsAccuracy,
             .builderDuration,
             .builderHeadingVariance,
             .builderSampleCount,
             .builderPartialAtSeal,
             .qualityGpsAccuracy,
             .qualitySpeed,
             .qualitySampleCount,
             .qualityDuration,
             .qualityThermal,
             .persistFailure:
            return .readingWindow
        }
    }
}

/// Counts per `ReadingDiagnosticReason`. Stored as a stable Codable shape so it
/// can be serialised to JSON for SwiftData blobs without a schema field per
/// reason. Unknown raw keys are tolerated so older stores can be decoded after
/// new reasons are added.
public struct ReadingDiagnosticTotals: Equatable, Sendable, Codable {
    public private(set) var counts: [String: Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.counts = (try? container.decode([String: Int].self)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counts)
    }

    public func count(for reason: ReadingDiagnosticReason) -> Int {
        counts[reason.rawValue] ?? 0
    }

    public func total(for unit: ReadingDiagnosticUnit) -> Int {
        ReadingDiagnosticReason.allCases
            .filter { $0.unit == unit }
            .reduce(0) { partial, reason in partial + count(for: reason) }
    }

    public mutating func increment(_ reason: ReadingDiagnosticReason, by amount: Int = 1) {
        guard amount > 0 else { return }
        counts[reason.rawValue, default: 0] += amount
    }

    public mutating func add(_ other: ReadingDiagnosticTotals) {
        for (key, value) in other.counts {
            counts[key, default: 0] += value
        }
    }

    public static let empty = ReadingDiagnosticTotals()

    public var isEmpty: Bool {
        counts.values.allSatisfy { $0 == 0 }
    }
}

public extension ReadingDiagnosticTotals {
    static func decode(fromJSON json: String?) -> ReadingDiagnosticTotals {
        guard let json,
              let data = json.data(using: .utf8) else {
            return .empty
        }
        return (try? JSONDecoder().decode(ReadingDiagnosticTotals.self, from: data)) ?? .empty
    }

    func encodedJSON() -> String? {
        guard !isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public extension QualityRejectionReason {
    var diagnosticReason: ReadingDiagnosticReason {
        switch self {
        case .gpsAccuracy:
            return .qualityGpsAccuracy
        case .speed:
            return .qualitySpeed
        case .sampleCount:
            return .qualitySampleCount
        case .duration:
            return .qualityDuration
        case .thermal:
            return .qualityThermal
        }
    }
}
