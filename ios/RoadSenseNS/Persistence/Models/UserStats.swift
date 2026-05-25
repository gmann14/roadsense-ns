import Foundation
import SwiftData

@Model
final class UserStats {
    @Attribute(.unique) var id: UUID
    var totalKmRecorded: Double
    var totalSegmentsContributed: Int
    var lastDriveAt: Date?
    var potholesReported: Int
    /// Codable JSON of `ReadingDiagnosticTotals` accumulated across the
    /// install lifetime. Optional and additive only — `nil` for fresh stores
    /// migrated from V5, populated lazily by `ReadingRejectionRecorder`.
    var rejectionTotalsJSON: String?

    init(
        id: UUID = UUID(),
        totalKmRecorded: Double = 0,
        totalSegmentsContributed: Int = 0,
        lastDriveAt: Date? = nil,
        potholesReported: Int = 0,
        rejectionTotalsJSON: String? = nil
    ) {
        self.id = id
        self.totalKmRecorded = totalKmRecorded
        self.totalSegmentsContributed = totalSegmentsContributed
        self.lastDriveAt = lastDriveAt
        self.potholesReported = potholesReported
        self.rejectionTotalsJSON = rejectionTotalsJSON
    }
}
