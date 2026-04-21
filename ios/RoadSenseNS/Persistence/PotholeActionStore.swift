import CoreLocation
import Foundation
import SwiftData

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

    func discard(id: UUID) throws {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context) else {
            return
        }

        context.delete(record)
        try context.save()
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

    private func compareDrainOrder(_ lhs: PotholeActionRecord, _ rhs: PotholeActionRecord) -> Bool {
        let lhsNextAttempt = lhs.nextAttemptAt ?? .distantPast
        let rhsNextAttempt = rhs.nextAttemptAt ?? .distantPast
        if lhsNextAttempt != rhsNextAttempt {
            return lhsNextAttempt < rhsNextAttempt
        }

        return lhs.createdAt < rhs.createdAt
    }
}
