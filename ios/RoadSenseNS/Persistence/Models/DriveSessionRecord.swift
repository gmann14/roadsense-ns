import Foundation
import SwiftData

@Model
final class DriveSessionRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var startLatitude: Double
    var startLongitude: Double
    var endLatitude: Double?
    var endLongitude: Double?
    var isSealed: Bool
    /// Codable JSON of `ReadingDiagnosticTotals` for this single session.
    /// Optional and additive only — `nil` for sessions written before V6.
    var rejectionTotalsJSON: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        startLatitude: Double,
        startLongitude: Double,
        endLatitude: Double? = nil,
        endLongitude: Double? = nil,
        isSealed: Bool = false,
        rejectionTotalsJSON: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
        self.isSealed = isSealed
        self.rejectionTotalsJSON = rejectionTotalsJSON
    }
}
