import Foundation

enum QueueModelMapper {
    static func makeQueueReading(from model: ReadingRecord) -> QueueReadingRecord {
        QueueReadingRecord(
            id: model.id,
            uploadBatchID: model.uploadBatchID,
            uploadedAt: model.uploadedAt
        )
    }

    static func apply(_ record: QueueReadingRecord, to model: ReadingRecord) {
        model.uploadBatchID = record.uploadBatchID
        model.uploadedAt = record.uploadedAt
    }

    static func makeQueueBatch(from model: UploadBatch) -> QueueUploadBatch {
        QueueUploadBatch(
            id: model.id,
            createdAt: model.createdAt,
            attemptCount: model.attemptCount,
            lastAttemptAt: model.lastAttemptAt,
            nextAttemptAt: model.nextAttemptAt,
            status: map(model.status),
            readingCount: model.readingCount,
            firstErrorMessage: model.firstErrorMessage,
            acceptedCount: model.acceptedCount,
            rejectedCount: model.rejectedCount,
            rejectedReasons: UploadBatchJSONCodec.decodeRejectedReasons(model.rejectedReasonsJSON),
            wasDuplicateOnResubmit: model.wasDuplicateOnResubmit
        )
    }

    static func apply(_ record: QueueUploadBatch, to model: UploadBatch) {
        model.createdAt = record.createdAt
        model.attemptCount = record.attemptCount
        model.lastAttemptAt = record.lastAttemptAt
        model.nextAttemptAt = record.nextAttemptAt
        model.status = map(record.status)
        model.readingCount = record.readingCount
        model.firstErrorMessage = record.firstErrorMessage
        model.acceptedCount = record.acceptedCount
        model.rejectedCount = record.rejectedCount
        model.rejectedReasonsJSON = UploadBatchJSONCodec.encodeRejectedReasons(record.rejectedReasons)
        model.wasDuplicateOnResubmit = record.wasDuplicateOnResubmit
    }

    private static func map(_ status: UploadStatus) -> QueueUploadStatus {
        switch status {
        case .pending:
            return .pending
        case .inFlight:
            return .inFlight
        case .succeeded:
            return .succeeded
        case .failedPermanent:
            return .failedPermanent
        }
    }

    private static func map(_ status: QueueUploadStatus) -> UploadStatus {
        switch status {
        case .pending:
            return .pending
        case .inFlight:
            return .inFlight
        case .succeeded:
            return .succeeded
        case .failedPermanent:
            return .failedPermanent
        }
    }
}
