import Foundation
import SwiftData

@Model
final class ReadingRecord {
    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double
    var roughnessRMS: Double
    var speedKMH: Double
    var heading: Double
    var gpsAccuracyM: Double
    var isPothole: Bool
    var potholeMagnitude: Double?
    var recordedAt: Date
    var uploadBatchID: UUID?
    var uploadedAt: Date?
    var droppedByPrivacyZone: Bool

    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        roughnessRMS: Double,
        speedKMH: Double,
        heading: Double,
        gpsAccuracyM: Double,
        isPothole: Bool,
        potholeMagnitude: Double?,
        recordedAt: Date,
        uploadBatchID: UUID? = nil,
        uploadedAt: Date? = nil,
        droppedByPrivacyZone: Bool = false
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.roughnessRMS = roughnessRMS
        self.speedKMH = speedKMH
        self.heading = heading
        self.gpsAccuracyM = gpsAccuracyM
        self.isPothole = isPothole
        self.potholeMagnitude = potholeMagnitude
        self.recordedAt = recordedAt
        self.uploadBatchID = uploadBatchID
        self.uploadedAt = uploadedAt
        self.droppedByPrivacyZone = droppedByPrivacyZone
    }
}
