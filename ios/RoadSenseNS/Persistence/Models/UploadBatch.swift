import Foundation
import SwiftData

@Model
final class UploadBatch {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var statusRawValue: String
    var readingCount: Int
    var firstErrorMessage: String?
    var acceptedCount: Int
    var rejectedCount: Int
    var rejectedReasonsJSON: String?
    var wasDuplicateOnResubmit: Bool

    var status: UploadStatus {
        get { UploadStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        status: UploadStatus,
        readingCount: Int,
        firstErrorMessage: String? = nil,
        acceptedCount: Int = 0,
        rejectedCount: Int = 0,
        rejectedReasonsJSON: String? = nil,
        wasDuplicateOnResubmit: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.statusRawValue = status.rawValue
        self.readingCount = readingCount
        self.firstErrorMessage = firstErrorMessage
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.rejectedReasonsJSON = rejectedReasonsJSON
        self.wasDuplicateOnResubmit = wasDuplicateOnResubmit
    }
}
