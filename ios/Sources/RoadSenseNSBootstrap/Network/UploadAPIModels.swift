import Foundation

public struct UploadReadingPayload: Codable, Equatable, Sendable {
    public let lat: Double
    public let lng: Double
    public let roughnessRms: Double
    public let speedKmh: Double
    /// `nil` when the heading is unknown; always encoded (as JSON `null`)
    /// because the gateway requires the key to be present.
    public let heading: Double?
    public let gpsAccuracyM: Double
    public let isPothole: Bool
    public let potholeMagnitude: Double?
    public let recordedAt: Date

    public init(
        lat: Double,
        lng: Double,
        roughnessRms: Double,
        speedKmh: Double,
        heading: Double?,
        gpsAccuracyM: Double,
        isPothole: Bool,
        potholeMagnitude: Double?,
        recordedAt: Date
    ) {
        self.lat = lat
        self.lng = lng
        self.roughnessRms = roughnessRms
        self.speedKmh = speedKmh
        // Negative / out-of-range values are CoreLocation's "unknown course"
        // sentinel; send null rather than a heading the server would reject
        // or, worse, read as due north.
        if let heading, heading.isFinite, heading >= 0, heading < 360 {
            self.heading = heading
        } else {
            self.heading = nil
        }
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lat: try container.decode(Double.self, forKey: .lat),
            lng: try container.decode(Double.self, forKey: .lng),
            roughnessRms: try container.decode(Double.self, forKey: .roughnessRms),
            speedKmh: try container.decode(Double.self, forKey: .speedKmh),
            heading: try container.decodeIfPresent(Double.self, forKey: .heading),
            gpsAccuracyM: try container.decode(Double.self, forKey: .gpsAccuracyM),
            isPothole: try container.decode(Bool.self, forKey: .isPothole),
            potholeMagnitude: try container.decodeIfPresent(Double.self, forKey: .potholeMagnitude),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lat, forKey: .lat)
        try container.encode(lng, forKey: .lng)
        try container.encode(roughnessRms, forKey: .roughnessRms)
        try container.encode(speedKmh, forKey: .speedKmh)
        // Explicit null: the gateway accepts `heading: null` but rejects a
        // missing key.
        if let heading {
            try container.encode(heading, forKey: .heading)
        } else {
            try container.encodeNil(forKey: .heading)
        }
        try container.encode(gpsAccuracyM, forKey: .gpsAccuracyM)
        try container.encode(isPothole, forKey: .isPothole)
        try container.encodeIfPresent(potholeMagnitude, forKey: .potholeMagnitude)
        try container.encode(recordedAt, forKey: .recordedAt)
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

public struct FeedbackSubmissionPayload: Codable, Equatable, Sendable {
    public let source: String
    public let category: String
    public let message: String
    public let replyEmail: String?
    public let contactConsent: Bool
    public let appVersion: String
    public let platform: String
    public let locale: String?
    public let route: String?

    public init(
        source: String,
        category: String,
        message: String,
        replyEmail: String?,
        contactConsent: Bool,
        appVersion: String,
        platform: String,
        locale: String?,
        route: String?
    ) {
        self.source = source
        self.category = category
        self.message = message
        self.replyEmail = replyEmail
        self.contactConsent = contactConsent
        self.appVersion = appVersion
        self.platform = platform
        self.locale = locale
        self.route = route
    }

    enum CodingKeys: String, CodingKey {
        case source
        case category
        case message
        case replyEmail = "reply_email"
        case contactConsent = "contact_consent"
        case appVersion = "app_version"
        case platform
        case locale
        case route
    }
}

public struct FeedbackSubmissionAcceptedResponse: Codable, Equatable, Sendable {
    public let id: String
    public let requestID: String?

    public init(id: String, requestID: String?) {
        self.id = id
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case requestID = "request_id"
    }
}

public struct FeedbackValidationErrorResponse: Codable, Equatable, Sendable {
    public let error: String
    public let message: String?
    public let requestID: String?
    public let fieldErrors: [String: String]

    public init(
        error: String,
        message: String?,
        requestID: String?,
        fieldErrors: [String: String]
    ) {
        self.error = error
        self.message = message
        self.requestID = requestID
        self.fieldErrors = fieldErrors
    }

    enum CodingKeys: String, CodingKey {
        case error
        case message
        case requestID = "request_id"
        case fieldErrors = "field_errors"
    }
}
