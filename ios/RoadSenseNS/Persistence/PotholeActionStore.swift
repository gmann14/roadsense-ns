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
        now: Date = Date()
    ) throws -> PotholeActionRecord {
        let context = ModelContext(container)
        let recordedAt = Date(timeIntervalSince1970: sample.timestamp)

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
            uploadState: .pendingUndo
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
            .filter { $0.uploadState != .failedPermanent }
            .count
    }

    func statusSummary(now: Date = Date()) throws -> PotholeActionStatusSummary {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())

        let pendingCount = records.filter { $0.uploadState != .failedPermanent }.count
        let failedPermanentCount = records.filter { $0.uploadState == .failedPermanent }.count
        let nextRetryAt = records
            .filter { $0.uploadState == .pendingUpload }
            .compactMap(\.nextAttemptAt)
            .filter { $0 > now }
            .min()
        let lastSuccessfulUploadAt = records
            .filter { $0.uploadState != .failedPermanent }
            .compactMap(\.lastAttemptAt)
            .max()

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
            .filter { $0.uploadState == .failedPermanent }
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
                record.actionType == .manualReport && record.uploadState != .failedPermanent
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

        for record in records {
            guard let undoExpiresAt = record.undoExpiresAt,
                  undoExpiresAt <= now else {
                continue
            }

            record.uploadState = .pendingUpload
            record.undoExpiresAt = nil
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
        let records = try context.fetch(descriptor).sorted(by: compareDrainOrder)

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

    func applyUploadSuccess(id: UUID) throws {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context) else {
            return
        }

        context.delete(record)
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
            context.delete(record)
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

    private func findPendingFollowUpDuplicate(
        potholeReportID: UUID,
        actionType: PotholeActionType,
        in context: ModelContext
    ) throws -> PotholeActionRecord? {
        let descriptor = FetchDescriptor<PotholeActionRecord>(
            predicate: #Predicate {
                $0.potholeReportID == potholeReportID &&
                    $0.actionTypeRawValue == actionType.rawValue &&
                    $0.uploadStateRawValue != "failed_permanent"
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
