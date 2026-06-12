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
    /// Set once the one-time re-offset of legacy raw zone centers has run.
    /// Zones saved before the offset fix stored the exact map-reticle
    /// coordinate (the user's home) in plaintext SwiftData.
    static let legacyCenterMigrationKey = "ca.roadsense.ios.privacy-zone-center-offset-migration"

    private let container: ModelContainer
    private let makeRandomAngleRadians: () -> Double
    private let makeRandomDistanceMeters: () -> Double

    init(
        container: ModelContainer,
        makeRandomAngleRadians: @escaping () -> Double = { Double.random(in: 0..<(2 * .pi)) },
        makeRandomDistanceMeters: @escaping () -> Double = { Double.random(in: 50...100) }
    ) {
        self.container = container
        self.makeRandomAngleRadians = makeRandomAngleRadians
        self.makeRandomDistanceMeters = makeRandomDistanceMeters
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
        // Persist only the grid-snapped + randomly offset center so the exact
        // home/work coordinate never hits disk (docs/implementation/
        // 06-security-and-privacy.md launch checklist).
        let zone = makeOffsetZone(latitude: latitude, longitude: longitude, radiusM: radiusM)
        let context = ModelContext(container)
        let record = PrivacyZoneRecord(
            label: label,
            latitude: zone.latitude,
            longitude: zone.longitude,
            radiusM: zone.radiusMeters,
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

    /// One-time migration: zones created before the offset fix stored the raw
    /// coordinate. Re-offset their centers so the exact home/work coordinate
    /// no longer exists on disk. The flag is set before mutating so a partial
    /// failure can never re-offset already-offset zones (a double offset could
    /// push the center far enough that the zone no longer covers home); a
    /// thrown error resets the flag so the next launch retries.
    func migrateLegacyRawZoneCentersIfNeeded(
        defaults: UserDefaults = .standard,
        logger: RoadSenseLogger
    ) {
        guard !defaults.bool(forKey: Self.legacyCenterMigrationKey) else {
            return
        }

        defaults.set(true, forKey: Self.legacyCenterMigrationKey)

        do {
            let context = ModelContext(container)
            let records = try context.fetch(FetchDescriptor<PrivacyZoneRecord>())
            guard !records.isEmpty else {
                return
            }

            for record in records {
                let zone = makeOffsetZone(
                    latitude: record.latitude,
                    longitude: record.longitude,
                    radiusM: record.radiusM
                )
                record.latitude = zone.latitude
                record.longitude = zone.longitude
                record.radiusM = zone.radiusMeters
            }
            try context.save()
            logger.info("re-offset \(records.count) legacy privacy zone center(s)")
        } catch {
            defaults.set(false, forKey: Self.legacyCenterMigrationKey)
            logger.error("failed to migrate legacy privacy zone centers: \(error.localizedDescription)")
        }
    }

    private func makeOffsetZone(latitude: Double, longitude: Double, radiusM: Double) -> PrivacyZone {
        PrivacyZoneFactory.makeZone(
            tappedLatitude: latitude,
            tappedLongitude: longitude,
            requestedRadiusMeters: radiusM,
            randomAngleRadians: makeRandomAngleRadians(),
            randomDistanceMeters: makeRandomDistanceMeters()
        )
    }
}
