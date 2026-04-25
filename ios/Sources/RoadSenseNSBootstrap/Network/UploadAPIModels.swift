import Foundation

public struct UploadReadingPayload: Codable, Equatable, Sendable {
    public let lat: Double
    public let lng: Double
    public let roughnessRms: Double
    public let speedKmh: Double
    public let heading: Double
    public let gpsAccuracyM: Double
    public let isPothole: Bool
    public let potholeMagnitude: Double?
    public let recordedAt: Date

    public init(
        lat: Double,
        lng: Double,
        roughnessRms: Double,
        speedKmh: Double,
        heading: Double,
        gpsAccuracyM: Double,
        isPothole: Bool,
        potholeMagnitude: Double?,
        recordedAt: Date
    ) {
        self.lat = lat
        self.lng = lng
        self.roughnessRms = roughnessRms
        self.speedKmh = speedKmh
        self.heading = heading
        self.gpsAccuracyM = gpsAccuracyM
        self.isPothole = isPothole
        self.potholeMagnitude = potholeMagnitude
        self.recordedAt = recordedAt
    }

    enum CodingKeys: String, CodingKey {
        case lat
        case lng
        case roughnessRms = "roughness_rms"
        case speedKmh = "speed_kmh"
        case heading
        case gpsAccuracyM = "gps_accuracy_m"
        case isPothole = "is_pothole"
        case potholeMagnitude = "pothole_magnitude"
        case recordedAt = "recorded_at"
    }
}

public struct UploadReadingsRequest: Codable, Equatable, Sendable {
    public let batchID: UUID
    public let deviceToken: String
    public let clientSentAt: Date
    public let clientAppVersion: String
    public let clientOSVersion: String
    public let readings: [UploadReadingPayload]

    public init(
        batchID: UUID,
        deviceToken: String,
        clientSentAt: Date,
        clientAppVersion: String,
        clientOSVersion: String,
        readings: [UploadReadingPayload]
    ) {
        self.batchID = batchID
        self.deviceToken = deviceToken
        self.clientSentAt = clientSentAt
        self.clientAppVersion = clientAppVersion
        self.clientOSVersion = clientOSVersion
        self.readings = readings
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case deviceToken = "device_token"
        case clientSentAt = "client_sent_at"
        case clientAppVersion = "client_app_version"
        case clientOSVersion = "client_os_version"
        case readings
    }
}

public struct UploadReadingsResponse: Codable, Equatable, Sendable {
    public let batchID: UUID
    public let accepted: Int
    public let rejected: Int
    public let duplicate: Bool
    public let rejectedReasons: [String: Int]

    public init(
        batchID: UUID,
        accepted: Int,
        rejected: Int,
        duplicate: Bool,
        rejectedReasons: [String: Int]
    ) {
        self.batchID = batchID
        self.accepted = accepted
        self.rejected = rejected
        self.duplicate = duplicate
        self.rejectedReasons = rejectedReasons
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case accepted
        case rejected
        case duplicate
        case rejectedReasons = "rejected_reasons"
    }
}

public struct UploadErrorEnvelope: Codable, Equatable, Sendable {
    public let error: String
    public let details: [String: String]?

    public init(error: String, details: [String: String]? = nil) {
        self.error = error
        self.details = details
    }
}

public struct PotholeActionUploadRequest: Codable, Equatable, Sendable {
    public let actionID: UUID
    public let deviceToken: String
    public let clientSentAt: Date
    public let clientAppVersion: String
    public let clientOSVersion: String
    public let actionType: String
    public let potholeReportID: UUID?
    public let lat: Double
    public let lng: Double
    public let accuracyM: Double
    public let recordedAt: Date
    public let sensorBackedMagnitudeG: Double?
    public let sensorBackedAt: Date?

    public init(
        actionID: UUID,
        deviceToken: String,
        clientSentAt: Date,
        clientAppVersion: String,
        clientOSVersion: String,
        actionType: String,
        potholeReportID: UUID?,
        lat: Double,
        lng: Double,
        accuracyM: Double,
        recordedAt: Date,
        sensorBackedMagnitudeG: Double? = nil,
        sensorBackedAt: Date? = nil
    ) {
        self.actionID = actionID
        self.deviceToken = deviceToken
        self.clientSentAt = clientSentAt
        self.clientAppVersion = clientAppVersion
        self.clientOSVersion = clientOSVersion
        self.actionType = actionType
        self.potholeReportID = potholeReportID
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.recordedAt = recordedAt
        self.sensorBackedMagnitudeG = sensorBackedMagnitudeG
        self.sensorBackedAt = sensorBackedAt
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case deviceToken = "device_token"
        case clientSentAt = "client_sent_at"
        case clientAppVersion = "client_app_version"
        case clientOSVersion = "client_os_version"
        case actionType = "action_type"
        case potholeReportID = "pothole_report_id"
        case lat
        case lng
        case accuracyM = "accuracy_m"
        case recordedAt = "recorded_at"
        case sensorBackedMagnitudeG = "sensor_backed_magnitude_g"
        case sensorBackedAt = "sensor_backed_at"
    }
}

public struct PotholeActionUploadResponse: Codable, Equatable, Sendable {
    public let actionID: UUID
    public let potholeReportID: UUID
    public let status: String

    public init(actionID: UUID, potholeReportID: UUID, status: String) {
        self.actionID = actionID
        self.potholeReportID = potholeReportID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case potholeReportID = "pothole_report_id"
        case status
    }
}

public struct PotholePhotoUploadRequest: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let segmentID: UUID?
    public let deviceToken: String
    public let clientSentAt: Date
    public let clientAppVersion: String
    public let clientOSVersion: String
    public let lat: Double
    public let lng: Double
    public let accuracyM: Double
    public let capturedAt: Date
    public let contentType: String
    public let byteSize: Int
    public let sha256: String

    public init(
        reportID: UUID,
        segmentID: UUID? = nil,
        deviceToken: String,
        clientSentAt: Date,
        clientAppVersion: String,
        clientOSVersion: String,
        lat: Double,
        lng: Double,
        accuracyM: Double,
        capturedAt: Date,
        contentType: String,
        byteSize: Int,
        sha256: String
    ) {
        self.reportID = reportID
        self.segmentID = segmentID
        self.deviceToken = deviceToken
        self.clientSentAt = clientSentAt
        self.clientAppVersion = clientAppVersion
        self.clientOSVersion = clientOSVersion
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.capturedAt = capturedAt
        self.contentType = contentType
        self.byteSize = byteSize
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case segmentID = "segment_id"
        case deviceToken = "device_token"
        case clientSentAt = "client_sent_at"
        case clientAppVersion = "client_app_version"
        case clientOSVersion = "client_os_version"
        case lat
        case lng
        case accuracyM = "accuracy_m"
        case capturedAt = "captured_at"
        case contentType = "content_type"
        case byteSize = "byte_size"
        case sha256
    }
}

public struct PotholePhotoUploadResponse: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let uploadURL: URL
    public let uploadExpiresAt: Date
    public let expectedObjectPath: String

    public init(
        reportID: UUID,
        uploadURL: URL,
        uploadExpiresAt: Date,
        expectedObjectPath: String
    ) {
        self.reportID = reportID
        self.uploadURL = uploadURL
        self.uploadExpiresAt = uploadExpiresAt
        self.expectedObjectPath = expectedObjectPath
    }

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case uploadURL = "upload_url"
        case uploadExpiresAt = "upload_expires_at"
        case expectedObjectPath = "expected_object_path"
    }
}
