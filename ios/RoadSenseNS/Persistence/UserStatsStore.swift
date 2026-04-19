import Foundation
import SwiftData

struct UserStatsSummary: Equatable {
    let totalKmRecorded: Double
    let totalSegmentsContributed: Int
    let lastDriveAt: Date?
    let potholesReported: Int
    let acceptedReadingCount: Int
    let privacyFilteredCount: Int
    let pendingUploadCount: Int

    static let zero = UserStatsSummary(
        totalKmRecorded: 0,
        totalSegmentsContributed: 0,
        lastDriveAt: nil,
        potholesReported: 0,
        acceptedReadingCount: 0,
        privacyFilteredCount: 0,
        pendingUploadCount: 0
    )
}

@MainActor
final class UserStatsStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func summary() throws -> UserStatsSummary {
        let context = ModelContext(container)

        var statsDescriptor = FetchDescriptor<UserStats>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        statsDescriptor.fetchLimit = 1
        let stats = try context.fetch(statsDescriptor).first

        let acceptedDescriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate { $0.droppedByPrivacyZone == false }
        )
        let filteredDescriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate { $0.droppedByPrivacyZone == true }
        )
        let pendingDescriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate {
                $0.droppedByPrivacyZone == false && $0.uploadedAt == nil
            }
        )

        return UserStatsSummary(
            totalKmRecorded: stats?.totalKmRecorded ?? 0,
            totalSegmentsContributed: stats?.totalSegmentsContributed ?? 0,
            lastDriveAt: stats?.lastDriveAt,
            potholesReported: stats?.potholesReported ?? 0,
            acceptedReadingCount: try context.fetchCount(acceptedDescriptor),
            privacyFilteredCount: try context.fetchCount(filteredDescriptor),
            pendingUploadCount: try context.fetchCount(pendingDescriptor)
        )
    }
}
