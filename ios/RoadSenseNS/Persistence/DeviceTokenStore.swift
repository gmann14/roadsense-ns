import Foundation
import SwiftData

@MainActor
enum DeviceTokenStore {
    static func currentToken(
        in context: ModelContext,
        now: Date = Date(),
        makeUUID: () -> String = { UUID().uuidString }
    ) throws -> DeviceTokenRecord {
        var descriptor = FetchDescriptor<DeviceTokenRecord>(
            sortBy: [SortDescriptor(\.issuedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        let existing = try context.fetch(descriptor).first
        let resolved = DeviceTokenManager.resolve(
            existing: existing.map {
                DeviceTokenRecordValue(
                    token: $0.token,
                    issuedAt: $0.issuedAt,
                    expiresAt: $0.expiresAt
                )
            },
            now: now,
            makeUUID: makeUUID
        )

        if let existing,
           existing.token == resolved.token,
           existing.issuedAt == resolved.issuedAt,
           existing.expiresAt == resolved.expiresAt {
            return existing
        }

        if let existing {
            context.delete(existing)
        }

        let record = DeviceTokenRecord(
            token: resolved.token,
            issuedAt: resolved.issuedAt,
            expiresAt: resolved.expiresAt
        )
        context.insert(record)
        return record
    }
}
