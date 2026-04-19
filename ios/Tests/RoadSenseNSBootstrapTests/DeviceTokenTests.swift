import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Device token rotation")
struct DeviceTokenTests {
    @Test("reuses a token that has not expired yet")
    func reusesUnexpiredToken() {
        let now = Date(timeIntervalSince1970: 1_000)
        let record = DeviceTokenRecordValue(
            token: "existing-token",
            issuedAt: now.addingTimeInterval(-1_000),
            expiresAt: now.addingTimeInterval(1_000)
        )

        let resolved = DeviceTokenManager.resolve(
            existing: record,
            now: now,
            makeUUID: { "new-token" }
        )

        #expect(resolved == record)
    }

    @Test("rotates a token once it expires")
    func rotatesExpiredToken() {
        let now = Date(timeIntervalSince1970: 10_000)
        let record = DeviceTokenRecordValue(
            token: "existing-token",
            issuedAt: now.addingTimeInterval(-4_000_000),
            expiresAt: now.addingTimeInterval(-1)
        )

        let resolved = DeviceTokenManager.resolve(
            existing: record,
            now: now,
            makeUUID: { "rotated-token" }
        )

        #expect(resolved.token == "rotated-token")
        #expect(resolved.issuedAt == now)
        #expect(resolved.expiresAt == now.addingTimeInterval(30 * 24 * 60 * 60))
    }
}
