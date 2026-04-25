import Foundation
import SwiftData

struct UserStatsSummary: Equatable {
    let totalKmRecorded: Double
    let totalSegmentsContributed: Int
    let totalTripsRecorded: Int
    let lastDriveAt: Date?
    let potholesReported: Int
    let acceptedReadingCount: Int
    let privacyFilteredCount: Int
    let pendingUploadCount: Int
    let pendingTripUploadCount: Int

    static let zero = UserStatsSummary(
        totalKmRecorded: 0,
        totalSegmentsContributed: 0,
        totalTripsRecorded: 0,
        lastDriveAt: nil,
        potholesReported: 0,
        acceptedReadingCount: 0,
        privacyFilteredCount: 0,
        pendingUploadCount: 0,
        pendingTripUploadCount: 0
    )
}

@MainActor
final class UserStatsStore {
    private static let fragmentedTripMergeGapSeconds: TimeInterval = 60

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
            predicate: #Predicate { $0.uploadedAt == nil }
        )
        let pendingReadings = try context.fetch(pendingDescriptor).filter(\.isReadyForUpload)
        let pendingCount = pendingReadings.count
        let undoableManualPotholesDescriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate {
                $0.actionTypeRawValue == "manual_report" &&
                    $0.uploadStateRawValue == "pending_undo"
            }
        )
        let undoableManualPotholeCount = try context.fetchCount(undoableManualPotholesDescriptor)
        let driveSessions = try context.fetch(
            FetchDescriptor<DriveSessionRecord>(
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
        )

        return UserStatsSummary(
            totalKmRecorded: stats?.totalKmRecorded ?? 0,
            totalSegmentsContributed: stats?.totalSegmentsContributed ?? 0,
            totalTripsRecorded: Self.groupedTripCount(for: driveSessions),
            lastDriveAt: stats?.lastDriveAt,
            potholesReported: (stats?.potholesReported ?? 0) + undoableManualPotholeCount,
            acceptedReadingCount: try context.fetchCount(acceptedDescriptor),
            privacyFilteredCount: try context.fetchCount(filteredDescriptor),
            pendingUploadCount: pendingCount,
            pendingTripUploadCount: Self.pendingTripUploadCount(
                pendingReadings: pendingReadings,
                driveSessions: driveSessions
            )
        )
    }

    private static func pendingTripUploadCount(
        pendingReadings: [ReadingRecord],
        driveSessions: [DriveSessionRecord]
    ) -> Int {
        let pendingSessionIDs = Set(pendingReadings.compactMap(\.driveSessionID))
        let pendingSessions = driveSessions.filter { pendingSessionIDs.contains($0.id) }
        let ungroupedPendingCount = pendingReadings.contains { $0.driveSessionID == nil } ? 1 : 0
        return groupedTripCount(for: pendingSessions) + ungroupedPendingCount
    }

    private static func groupedTripCount(for driveSessions: [DriveSessionRecord]) -> Int {
        var tripCount = 0
        var previousEndedAt: Date?

        for session in driveSessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            let sessionEnd = resolvedEnd(for: session)
            if let lastEndedAt = previousEndedAt,
               session.startedAt.timeIntervalSince(lastEndedAt) <= fragmentedTripMergeGapSeconds {
                previousEndedAt = max(lastEndedAt, sessionEnd)
                continue
            }

            tripCount += 1
            previousEndedAt = sessionEnd
        }

        return tripCount
    }

    private static func resolvedEnd(for session: DriveSessionRecord) -> Date {
        session.endedAt ?? session.startedAt
    }
}
