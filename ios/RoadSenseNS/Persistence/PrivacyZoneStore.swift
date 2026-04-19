import Foundation
import SwiftData

@MainActor
protocol PrivacyZoneStoring {
    func fetchAll() throws -> [PrivacyZoneRecord]
    func hasConfiguredZones() throws -> Bool
    func save(label: String, latitude: Double, longitude: Double, radiusM: Double) throws
    func delete(id: UUID) throws
}

@MainActor
final class PrivacyZoneStore: PrivacyZoneStoring {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func fetchAll() throws -> [PrivacyZoneRecord] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PrivacyZoneRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func hasConfiguredZones() throws -> Bool {
        try !fetchAll().isEmpty
    }

    func save(label: String, latitude: Double, longitude: Double, radiusM: Double) throws {
        let context = ModelContext(container)
        let record = PrivacyZoneRecord(
            label: label,
            latitude: latitude,
            longitude: longitude,
            radiusM: max(radiusM, 250),
            createdAt: Date()
        )
        context.insert(record)
        try context.save()
    }

    func delete(id: UUID) throws {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PrivacyZoneRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let record = try context.fetch(descriptor).first {
            context.delete(record)
            try context.save()
        }
    }
}
