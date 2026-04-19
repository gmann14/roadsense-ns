import Foundation
import SwiftData

@Model
final class UserStats {
    @Attribute(.unique) var id: UUID
    var totalKmRecorded: Double
    var totalSegmentsContributed: Int
    var lastDriveAt: Date?
    var potholesReported: Int

    init(
        id: UUID = UUID(),
        totalKmRecorded: Double = 0,
        totalSegmentsContributed: Int = 0,
        lastDriveAt: Date? = nil,
        potholesReported: Int = 0
    ) {
        self.id = id
        self.totalKmRecorded = totalKmRecorded
        self.totalSegmentsContributed = totalSegmentsContributed
        self.lastDriveAt = lastDriveAt
        self.potholesReported = potholesReported
    }
}
