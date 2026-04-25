import CoreLocation
import Foundation
import SwiftData

struct PotholeActionStatusSummary: Equatable {
    let pendingCount: Int
    let failedPermanentCount: Int
    let nextRetryAt: Date?
    let lastSuccessfulUploadAt: Date?

    static let empty = PotholeActionStatusSummary(
        pendingCount: 0,
        failedPermanentCount: 0,
        nextRetryAt: nil,
        lastSuccessfulUploadAt: nil
    )
}

struct FailedPotholeActionSummary: Identifiable, Equatable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let recordedAt: Date
    let lastHTTPStatusCode: Int?
}

@MainActor
final class PotholeActionStore {
    private let container: ModelContainer

    enum DrainDecision {
        case ready(PotholeActionRecord)
        case blocked(nextAttemptAt: Date)
        case none
    }

    init(container: ModelContainer) {
        self.container = container
    }

    func queueManualReport(
        sample: LocationSample,
        sensorBackedCandidate: PotholeCandidate? = nil,
        now: Date = Date()
    ) throws -> PotholeActionRecord {
        let context = ModelContext(container)
        let recordedAt = Date(timeIntervalSince1970: sample.timestamp)
        let sensorBackedAt = sensorBackedCandidate.map {
            Date(timeIntervalSince1970: $0.timestamp)
        }

        if let existing = try findPendingUndoDuplicate(
            sample: sample,
            recordedAt: recordedAt,
            in: context
        ) {
            existing.latitude = sample.latitude
            existing.longitude = sample.longitude
            existing.accuracyM = sample.horizontalAccuracyMeters
            existing.recordedAt = recordedAt
            existing.createdAt = now
            existing.undoExpiresAt = now.addingTimeInterval(5)
            existing.sensorBackedMagnitudeG = sensorBackedCandidate?.magnitudeG
            existing.sensorBackedAt = sensorBackedAt
            try context.save()
            return existing
        }

        let record = PotholeActionRecord(
            actionType: .manualReport,
            latitude: sample.latitude,
            longitude: sample.longitude,
            accuracyM: sample.horizontalAccuracyMeters,
            recordedAt: recordedAt,
            createdAt: now,
            undoExpiresAt: now.addingTimeInterval(5),
            uploadState: .pendingUndo,
            sensorBackedMagnitudeG: sensorBackedCandidate?.magnitudeG,
            sensorBackedAt: sensorBackedAt
        )
        context.insert(record)
        try context.save()
        return record
    }

    func queueFollowUpAction(
        potholeReportID: UUID,
        actionType: PotholeActionType,
        sample: LocationSample,
        now: Date = Date()
    ) throws -> PotholeActionRecord {
        precondition(actionType != .manualReport, "Use queueManualReport for manual reports")

        let context = ModelContext(container)
        let recordedAt = Date(timeIntervalSince1970: sample.timestamp)

        if let existing = try findPendingFollowUpDuplicate(
            potholeReportID: potholeReportID,
            actionType: actionType,
            in: context
        ) {
            existing.latitude = sample.latitude
            existing.longitude = sample.longitude
            existing.accuracyM = sample.horizontalAccuracyMeters
            existing.recordedAt = recordedAt
            existing.createdAt = now
            try context.save()
            return existing
        }

        let record = PotholeActionRecord(
            potholeReportID: potholeReportID,
            actionType: actionType,
            latitude: sample.latitude,
            longitude: sample.longitude,
            accuracyM: sample.horizontalAccuracyMeters,
            recordedAt: recordedAt,
            createdAt: now,
            uploadState: .pendingUpload
        )
        context.insert(record)
        try context.save()
        return record
    }

    func discard(id: UUID, now: Date = Date()) throws {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context) else {
            return
        }
        guard record.uploadState == .pendingUndo else {
            return
        }
        guard let undoExpiresAt = record.undoExpiresAt,
              undoExpiresAt > now else {
            return
        }

        context.delete(record)
        try context.save()
    }

    func pendingCount() throws -> Int {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<PotholeActionRecord>())
            .filter { $0.uploadedAt == nil && $0.uploadState != .failedPermanent }
            .count
    }

    func statusSummary(now: Date = Date()) throws -> PotholeActionStatusSummary {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())

        let pendingCount = records
            .filter { $0.uploadedAt == nil && $0.uploadState != .failedPermanent }
            .count
        let failedPermanentCount = records
            .filter { $0.uploadedAt == nil && $0.uploadState == .failedPermanent }
            .count
        let nextRetryAt = records
            .filter { $0.uploadedAt == nil && $0.uploadState == .pendingUpload }
            .compactMap(\.nextAttemptAt)
            .filter { $0 > now }
            .min()
        let lastSuccessfulUploadAt = records.compactMap(\.uploadedAt).max()

        return PotholeActionStatusSummary(
            pendingCount: pendingCount,
            failedPermanentCount: failedPermanentCount,
            nextRetryAt: nextRetryAt,
            lastSuccessfulUploadAt: lastSuccessfulUploadAt
        )
    }

    func failedPermanentActions(limit: Int = 10) throws -> [FailedPotholeActionSummary] {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>(
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        ))

        return records
            .filter { $0.uploadedAt == nil && $0.uploadState == .failedPermanent }
            .prefix(max(limit, 0))
            .map { record in
                FailedPotholeActionSummary(
                    id: record.id,
                    latitude: record.latitude,
                    longitude: record.longitude,
                    recordedAt: record.recordedAt,
                    lastHTTPStatusCode: record.lastHTTPStatusCode
                )
            }
    }

    func pendingManualReportCoordinates(limit: Int = 100) throws -> [CLLocationCoordinate2D] {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))

        return records
            .filter { record in
                record.uploadedAt == nil &&
                    record.actionType == .manualReport &&
                    record.uploadState != .failedPermanent
            }
            .prefix(max(limit, 0))
            .map { record in
                CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude)
            }
    }

    func retryFailedActions(ids: [UUID]? = nil) throws {
        let context = ModelContext(container)
        let retryIDs = ids.map(Set.init)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        var didChange = false

        for record in records where record.uploadState == .failedPermanent {
            guard retryIDs?.contains(record.id) ?? true else {
                continue
            }

            resetForRetry(record)
            didChange = true
        }

        if didChange {
            try context.save()
        }
    }

    @discardableResult
    func recoverRecoverableFailures() throws -> Int {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        var recovered = 0

        for record in records where record.uploadState == .failedPermanent {
            guard Self.isRecoverableFailureStatus(record.lastHTTPStatusCode) else {
                continue
            }

            resetForRetry(record)
            recovered += 1
        }

        if recovered > 0 {
            try context.save()
        }

        return recovered
    }

    @discardableResult
    func reconcileManualReportStats() throws -> Int {
        let context = ModelContext(container)
        let committedManualReportsDescriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate {
                $0.actionTypeRawValue == "manual_report" &&
                    $0.uploadStateRawValue != "pending_undo"
            }
        )
        let acceptedSensorPotholesDescriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate {
                $0.droppedByPrivacyZone == false &&
                    $0.isPothole == true
            }
        )
        let committedManualReportCount = try context.fetchCount(committedManualReportsDescriptor)
        let acceptedSensorPotholeCount = try context.fetchCount(acceptedSensorPotholesDescriptor)
        let minimumPotholeCount = committedManualReportCount + acceptedSensorPotholeCount
        guard minimumPotholeCount > 0 else {
            return 0
        }

        let stats = try fetchOrCreateStats(in: context)
        let recoveredCount = max(0, minimumPotholeCount - stats.potholesReported)
        guard recoveredCount > 0 else {
            return 0
        }

        stats.potholesReported += recoveredCount
        try context.save()
        return recoveredCount
    }

    private static func isRecoverableFailureStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else {
            return false
        }

        if statusCode == 404 || statusCode == 408 || statusCode == 429 {
            return true
        }

        return (500...599).contains(statusCode)
    }

    private func resetForRetry(_ record: PotholeActionRecord) {
        record.uploadState = .pendingUpload
        record.uploadAttemptCount = 0
        record.lastAttemptAt = nil
        record.nextAttemptAt = nil
        record.lastHTTPStatusCode = nil
        record.lastRequestID = nil
    }

    func deleteAllActions() throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())

        for record in records {
            context.delete(record)
        }

        if !records.isEmpty {
            try context.save()
        }
    }

    @discardableResult
    func promoteExpiredPendingUndoActions(now: Date = Date()) throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate { $0.uploadStateRawValue == "pending_undo" }
        )
        let records = try context.fetch(descriptor)
        var promoted = 0
        var stats: UserStats?

        for record in records {
            guard let undoExpiresAt = record.undoExpiresAt,
                  undoExpiresAt <= now else {
                continue
            }

            record.uploadState = .pendingUpload
            record.undoExpiresAt = nil
            if record.actionType == .manualReport {
                if stats == nil {
                    stats = try fetchOrCreateStats(in: context)
                }
                stats?.potholesReported += 1
            }
            promoted += 1
        }

        if promoted > 0 {
            try context.save()
        }

        return promoted
    }

    func prepareNextAction(now: Date = Date()) throws -> DrainDecision {
        _ = try promoteExpiredPendingUndoActions(now: now)

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PotholeActionRecord>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let records = try context.fetch(descriptor)
            .filter { $0.uploadedAt == nil }
            .sorted(by: compareDrainOrder)

        for record in records {
            switch record.uploadState {
            case .failedPermanent:
                continue
            case .pendingUndo:
                if let undoExpiresAt = record.undoExpiresAt, undoExpiresAt > now {
                    continue
                }
                record.uploadState = .pendingUpload
                record.undoExpiresAt = nil
                if record.actionType == .manualReport {
                    let stats = try fetchOrCreateStats(in: context)
                    stats.potholesReported += 1
                }
                try context.save()
                return .ready(record)
            case .pendingUpload:
                if let nextAttemptAt = record.nextAttemptAt, nextAttemptAt > now {
                    return .blocked(nextAttemptAt: nextAttemptAt)
                }
                return .ready(record)
            }
        }

        return .none
    }

    func applyUploadSuccess(id: UUID, now: Date = Date()) throws {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context) else {
            return
        }

        // Soft-delete: keep the row but mark it uploaded so reconcileManualReportStats
        // can still see the count even after a clean server accept.
        record.uploadedAt = now
        record.nextAttemptAt = nil
        try context.save()
    }

    func applyUploadFailure(
        id: UUID,
        disposition: UploadDisposition,
        attemptResult: UploadAttemptResult,
        requestID: String?,
        now: Date = Date()
    ) throws {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context) else {
            return
        }

        record.uploadAttemptCount += 1
        record.lastAttemptAt = now
        record.lastRequestID = requestID
        if case let .http(statusCode, _) = attemptResult {
            record.lastHTTPStatusCode = statusCode
        }

        switch disposition {
        case .succeeded:
            record.uploadedAt = now
            record.nextAttemptAt = nil
        case let .retry(afterSeconds):
            record.uploadState = .pendingUpload
            record.nextAttemptAt = now.addingTimeInterval(afterSeconds)
        case .failedPermanent:
            record.uploadState = .failedPermanent
            record.nextAttemptAt = nil
        }

        try context.save()
    }

    private func findPendingUndoDuplicate(
        sample: LocationSample,
        recordedAt: Date,
        in context: ModelContext
    ) throws -> PotholeActionRecord? {
        let descriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate {
                $0.uploadStateRawValue == "pending_undo" && $0.actionTypeRawValue == "manual_report"
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        return try context.fetch(descriptor).first(where: { record in
            abs(record.recordedAt.timeIntervalSince(recordedAt)) <= 8 &&
                CLLocation(
                    latitude: record.latitude,
                    longitude: record.longitude
                ).distance(from: CLLocation(latitude: sample.latitude, longitude: sample.longitude)) <= 20
        })
    }

    private func fetchRecord(id: UUID, in context: ModelContext) throws -> PotholeActionRecord? {
        var descriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchOrCreateStats(in context: ModelContext) throws -> UserStats {
        var descriptor = FetchDescriptor<UserStats>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        descriptor.fetchLimit = 1

        if let stats = try context.fetch(descriptor).first {
            return stats
        }

        let stats = UserStats()
        context.insert(stats)
        return stats
    }

    private func findPendingFollowUpDuplicate(
        potholeReportID: UUID,
        actionType: PotholeActionType,
        in context: ModelContext
    ) throws -> PotholeActionRecord? {
        let descriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate {
                $0.potholeReportID == potholeReportID &&
                    $0.actionTypeRawValue == actionType.rawValue &&
                    $0.uploadStateRawValue != "failed_permanent" &&
                    $0.uploadedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        return try context.fetch(descriptor).first
    }

    private func compareDrainOrder(_ lhs: PotholeActionRecord, _ rhs: PotholeActionRecord) -> Bool {
        let lhsNextAttempt = lhs.nextAttemptAt ?? .distantPast
        let rhsNextAttempt = rhs.nextAttemptAt ?? .distantPast
        if lhsNextAttempt != rhsNextAttempt {
            return lhsNextAttempt < rhsNextAttempt
        }

        return lhs.createdAt < rhs.createdAt
    }
}
