import Foundation

public enum QueueUploadStatus: Equatable, Sendable {
    case pending
    case inFlight
    case succeeded
    case failedPermanent
}

public struct QueueReadingRecord: Equatable, Sendable {
    public let id: UUID
    public let uploadBatchID: UUID?
    public let uploadedAt: Date?

    public init(
        id: UUID = UUID(),
        uploadBatchID: UUID? = nil,
        uploadedAt: Date? = nil
    ) {
        self.id = id
        self.uploadBatchID = uploadBatchID
        self.uploadedAt = uploadedAt
    }

    public func assigning(batchID: UUID) -> QueueReadingRecord {
        QueueReadingRecord(id: id, uploadBatchID: batchID, uploadedAt: uploadedAt)
    }

    public func markingUploaded(at date: Date) -> QueueReadingRecord {
        QueueReadingRecord(id: id, uploadBatchID: uploadBatchID, uploadedAt: date)
    }
}

public struct QueueUploadBatch: Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let attemptCount: Int
    public let lastAttemptAt: Date?
    public let nextAttemptAt: Date?
    public let status: QueueUploadStatus
    public let readingCount: Int
    public let firstErrorMessage: String?
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let rejectedReasons: [String: Int]
    public let wasDuplicateOnResubmit: Bool

    public init(
            id: UUID,
            createdAt: Date,
            attemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            nextAttemptAt: Date? = nil,
            status: QueueUploadStatus,
            readingCount: Int,
            firstErrorMessage: String? = nil,
            acceptedCount: Int = 0,
        rejectedCount: Int = 0,
        rejectedReasons: [String: Int] = [:],
        wasDuplicateOnResubmit: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.status = status
        self.readingCount = readingCount
        self.firstErrorMessage = firstErrorMessage
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.rejectedReasons = rejectedReasons
        self.wasDuplicateOnResubmit = wasDuplicateOnResubmit
    }
}

public struct UploadServerResult: Equatable, Sendable {
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let rejectedReasons: [String: Int]
    public let wasDuplicateOnResubmit: Bool

    public init(
        acceptedCount: Int,
        rejectedCount: Int,
        rejectedReasons: [String: Int],
        wasDuplicateOnResubmit: Bool
    ) {
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.rejectedReasons = rejectedReasons
        self.wasDuplicateOnResubmit = wasDuplicateOnResubmit
    }
}

public struct UploadSuccessOutcome: Equatable, Sendable {
    public let batch: QueueUploadBatch
    public let readings: [QueueReadingRecord]
}

public enum QueuePreparationDecision: Equatable, Sendable {
    case none
    case ready(QueueUploadBatch, [QueueReadingRecord])
}

public enum UploadQueueCore {
    public static func prepareNextBatch(
        pendingReadings: [QueueReadingRecord],
        existingBatch: QueueUploadBatch?,
        now: Date,
        inFlightTimeout: TimeInterval = 5 * 60,
        makeBatchID: () -> UUID
    ) -> QueuePreparationDecision {
        if let existingBatch {
            switch existingBatch.status {
            case .pending:
                if let nextAttemptAt = existingBatch.nextAttemptAt, nextAttemptAt > now {
                    return .none
                }
                return .ready(existingBatch, pendingReadings)
            case .inFlight:
                if let lastAttemptAt = existingBatch.lastAttemptAt,
                   now.timeIntervalSince(lastAttemptAt) < inFlightTimeout {
                    return .none
                }
                return .ready(existingBatch, pendingReadings)
            case .succeeded, .failedPermanent:
                break
            }
        }

        let unassigned = pendingReadings.filter { $0.uploadBatchID == nil && $0.uploadedAt == nil }
        guard !unassigned.isEmpty else {
            return .none
        }

        let selectedIDs = Set(unassigned.prefix(1_000).map(\.id))
        let batchID = makeBatchID()
        let updatedReadings = pendingReadings.map { reading in
            selectedIDs.contains(reading.id) ? reading.assigning(batchID: batchID) : reading
        }

        let batch = QueueUploadBatch(
            id: batchID,
            createdAt: now,
            nextAttemptAt: nil,
            status: .pending,
            readingCount: selectedIDs.count
        )

        return .ready(batch, updatedReadings)
    }

    public static func markInFlight(
        batch: QueueUploadBatch,
        now: Date
    ) -> QueueUploadBatch {
        QueueUploadBatch(
            id: batch.id,
            createdAt: batch.createdAt,
            attemptCount: batch.attemptCount,
            lastAttemptAt: now,
            nextAttemptAt: batch.nextAttemptAt,
            status: .inFlight,
            readingCount: batch.readingCount,
            firstErrorMessage: batch.firstErrorMessage,
            acceptedCount: batch.acceptedCount,
            rejectedCount: batch.rejectedCount,
            rejectedReasons: batch.rejectedReasons,
            wasDuplicateOnResubmit: batch.wasDuplicateOnResubmit
        )
    }

    public static func applySuccess(
        batch: QueueUploadBatch,
        readings: [QueueReadingRecord],
        result: UploadServerResult,
        now: Date
    ) -> UploadSuccessOutcome {
        let updatedBatch = QueueUploadBatch(
            id: batch.id,
            createdAt: batch.createdAt,
            attemptCount: batch.attemptCount,
            lastAttemptAt: now,
            nextAttemptAt: nil,
            status: .succeeded,
            readingCount: batch.readingCount,
            firstErrorMessage: batch.firstErrorMessage,
            acceptedCount: result.acceptedCount,
            rejectedCount: result.rejectedCount,
            rejectedReasons: result.rejectedReasons,
            wasDuplicateOnResubmit: result.wasDuplicateOnResubmit
        )

        let updatedReadings = readings.map { reading in
            guard reading.uploadBatchID == batch.id else {
                return reading
            }

            return reading.markingUploaded(at: now)
        }

        return UploadSuccessOutcome(batch: updatedBatch, readings: updatedReadings)
    }

    public static func applyFailure(
        batch: QueueUploadBatch,
        disposition: UploadDisposition,
        errorMessage: String?,
        now: Date
    ) -> QueueUploadBatch {
        let nextAttemptCount = batch.attemptCount + 1
        let nextStatus: QueueUploadStatus

        switch disposition {
        case .failedPermanent:
            nextStatus = .failedPermanent
        case .retry, .succeeded:
            nextStatus = .pending
        }

        let nextAttemptAt: Date?
        switch disposition {
        case let .retry(afterSeconds):
            nextAttemptAt = now.addingTimeInterval(afterSeconds)
        case .failedPermanent, .succeeded:
            nextAttemptAt = nil
        }

        return QueueUploadBatch(
            id: batch.id,
            createdAt: batch.createdAt,
            attemptCount: nextAttemptCount,
            lastAttemptAt: now,
            nextAttemptAt: nextAttemptAt,
            status: nextStatus,
            readingCount: batch.readingCount,
            firstErrorMessage: batch.firstErrorMessage ?? errorMessage,
            acceptedCount: batch.acceptedCount,
            rejectedCount: batch.rejectedCount,
            rejectedReasons: batch.rejectedReasons,
            wasDuplicateOnResubmit: batch.wasDuplicateOnResubmit
        )
    }
}
