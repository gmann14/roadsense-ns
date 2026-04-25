import Foundation
import SwiftData

enum PotholeActionType: String, Codable {
    case manualReport = "manual_report"
    case confirmPresent = "confirm_present"
    case confirmFixed = "confirm_fixed"
}

enum PotholeActionUploadState: String, Codable {
    case pendingUndo = "pending_undo"
    case pendingUpload = "pending_upload"
    case failedPermanent = "failed_permanent"
}

@Model
final class PotholeActionRecord {
    @Attribute(.unique) var id: UUID
    var potholeReportID: UUID?
    var actionTypeRawValue: String
    var latitude: Double
    var longitude: Double
    var accuracyM: Double
    var recordedAt: Date
    var createdAt: Date
    var undoExpiresAt: Date?
    var uploadStateRawValue: String
    var uploadAttemptCount: Int
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var lastHTTPStatusCode: Int?
    var lastRequestID: String?
    var sensorBackedMagnitudeG: Double?
    var sensorBackedAt: Date?
    /// Set when the server has accepted this action. We keep the row around
    /// rather than deleting it so `reconcileManualReportStats` can recover the
    /// count even after a clean upload — see ADR 0001 (additive schema rule)
    /// and the design-audit follow-up on stat-loss after upload.
    var uploadedAt: Date?

    var actionType: PotholeActionType {
        get { PotholeActionType(rawValue: actionTypeRawValue) ?? .manualReport }
        set { actionTypeRawValue = newValue.rawValue }
    }

    var uploadState: PotholeActionUploadState {
        get { PotholeActionUploadState(rawValue: uploadStateRawValue) ?? .pendingUndo }
        set { uploadStateRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        potholeReportID: UUID? = nil,
        actionType: PotholeActionType,
        latitude: Double,
        longitude: Double,
        accuracyM: Double,
        recordedAt: Date,
        createdAt: Date,
        undoExpiresAt: Date? = nil,
        uploadState: PotholeActionUploadState,
        uploadAttemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        lastHTTPStatusCode: Int? = nil,
        lastRequestID: String? = nil,
        sensorBackedMagnitudeG: Double? = nil,
        sensorBackedAt: Date? = nil,
        uploadedAt: Date? = nil
    ) {
        self.id = id
        self.potholeReportID = potholeReportID
        self.actionTypeRawValue = actionType.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyM = accuracyM
        self.recordedAt = recordedAt
        self.createdAt = createdAt
        self.undoExpiresAt = undoExpiresAt
        self.uploadStateRawValue = uploadState.rawValue
        self.uploadAttemptCount = uploadAttemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.lastHTTPStatusCode = lastHTTPStatusCode
        self.lastRequestID = lastRequestID
        self.sensorBackedMagnitudeG = sensorBackedMagnitudeG
        self.sensorBackedAt = sensorBackedAt
        self.uploadedAt = uploadedAt
    }
}
