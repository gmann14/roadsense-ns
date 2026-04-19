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
    public let readings: [UploadReadingPayload]

    public init(
        batchID: UUID,
        deviceToken: String,
        readings: [UploadReadingPayload]
    ) {
        self.batchID = batchID
        self.deviceToken = deviceToken
        self.readings = readings
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case deviceToken = "device_token"
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
