import Foundation

public struct UploadBatchDiagnosticEntry: Equatable, Sendable {
    public let recordedAt: Date
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let rejectedReasons: [String: Int]

    public init(
        recordedAt: Date,
        acceptedCount: Int,
        rejectedCount: Int,
        rejectedReasons: [String: Int]
    ) {
        self.recordedAt = recordedAt
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.rejectedReasons = rejectedReasons
    }
}

public enum IngestHealthState: Equatable, Sendable {
    case healthy
    case degraded(reason: String, ratio: Double)
}

public enum IngestHealthEvaluator {
    public static func evaluate(
        entries: [UploadBatchDiagnosticEntry],
        now: Date
    ) -> IngestHealthState {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recent = entries.filter { $0.recordedAt >= cutoff }

        let accepted = recent.reduce(0) { $0 + $1.acceptedCount }
        let rejected = recent.reduce(0) { $0 + $1.rejectedCount }
        let total = accepted + rejected

        guard total > 0 else {
            return .healthy
        }

        let ratio = Double(rejected) / Double(total)
        guard ratio > 0.20 else {
            return .healthy
        }

        let reasonCounts = recent.reduce(into: [String: Int]()) { partialResult, entry in
            for (reason, count) in entry.rejectedReasons {
                partialResult[reason, default: 0] += count
            }
        }

        guard let topReason = reasonCounts.max(by: { $0.value < $1.value })?.key,
              actionableReasons.contains(topReason) else {
            return .healthy
        }

        return .degraded(reason: topReason, ratio: ratio)
    }

    private static let actionableReasons: Set<String> = [
        "low_quality",
        "stale_timestamp",
        "unpaved",
    ]
}
