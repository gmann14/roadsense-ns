import Foundation
import SwiftData

@Model
final class PrivacyZoneRecord {
    @Attribute(.unique) var id: UUID
    var label: String
    var latitude: Double
    var longitude: Double
    var radiusM: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        latitude: Double,
        longitude: Double,
        radiusM: Double,
        createdAt: Date
    ) {
        self.id = id
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.radiusM = radiusM
        self.createdAt = createdAt
    }
}
