import Foundation

public struct DeviceTokenRecordValue: Equatable, Sendable {
    public let token: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(token: String, issuedAt: Date, expiresAt: Date) {
        self.token = token
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public enum DeviceTokenManager {
    public static func resolve(
        existing: DeviceTokenRecordValue?,
        now: Date,
        makeUUID: () -> String
    ) -> DeviceTokenRecordValue {
        if let existing, existing.expiresAt > now {
            return existing
        }

        return DeviceTokenRecordValue(
            token: makeUUID(),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }
}
