import Foundation
import SwiftData

enum PhotoUploadState: String, Codable {
    case pendingMetadata = "pending_metadata"
    case pendingModeration = "pending_moderation"
    case failedPermanent = "failed_permanent"
}

@Model
final class PotholeReportRecord {
    @Attribute(.unique) var id: UUID
    var segmentID: UUID?
    var photoFilePath: String
    var latitude: Double
    var longitude: Double
    var accuracyM: Double
    var capturedAt: Date
    var uploadStateRawValue: String
    var uploadAttemptCount: Int
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var expectedObjectPath: String?
    var byteSize: Int
    var sha256Hex: String
    var lastHTTPStatusCode: Int?
    var lastRequestID: String?

    var uploadState: PhotoUploadState {
        get { PhotoUploadState(rawValue: uploadStateRawValue) ?? .pendingMetadata }
        set { uploadStateRawValue = newValue.rawValue }
    }

    var photoFileURL: URL {
        URL(fileURLWithPath: photoFilePath)
    }

    init(
        id: UUID = UUID(),
        segmentID: UUID? = nil,
        photoFilePath: String,
        latitude: Double,
        longitude: Double,
        accuracyM: Double,
        capturedAt: Date,
        uploadState: PhotoUploadState,
        uploadAttemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        expectedObjectPath: String? = nil,
        byteSize: Int,
        sha256Hex: String,
        lastHTTPStatusCode: Int? = nil,
        lastRequestID: String? = nil
    ) {
        self.id = id
        self.segmentID = segmentID
        self.photoFilePath = photoFilePath
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyM = accuracyM
        self.capturedAt = capturedAt
        self.uploadStateRawValue = uploadState.rawValue
        self.uploadAttemptCount = uploadAttemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.expectedObjectPath = expectedObjectPath
        self.byteSize = byteSize
        self.sha256Hex = sha256Hex
        self.lastHTTPStatusCode = lastHTTPStatusCode
        self.lastRequestID = lastRequestID
    }
}
