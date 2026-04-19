import Foundation
import SwiftData

@Model
final class DeviceTokenRecord {
    @Attribute(.unique) var id: UUID
    var token: String
    var issuedAt: Date
    var expiresAt: Date

    init(
        id: UUID = UUID(),
        token: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.token = token
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}
