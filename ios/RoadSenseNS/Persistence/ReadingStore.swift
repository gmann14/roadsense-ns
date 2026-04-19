import Foundation
import SwiftData

@MainActor
final class ReadingStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func saveAccepted(_ candidate: PersistedReadingCandidate) throws {
        let context = ModelContext(container)
        let record = ReadingRecord(
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            roughnessRMS: candidate.roughnessRMS,
            speedKMH: candidate.speedKmh,
            heading: candidate.headingDegrees,
            gpsAccuracyM: candidate.gpsAccuracyMeters,
            isPothole: candidate.isPothole,
            potholeMagnitude: candidate.potholeMagnitudeG,
            recordedAt: candidate.recordedAt
        )
        context.insert(record)

        let stats = try fetchOrCreateStats(in: context)
        stats.totalKmRecorded += max(candidate.speedKmh, 0) * candidate.durationSeconds / 3600
        stats.totalSegmentsContributed += 1
        stats.lastDriveAt = candidate.recordedAt
        if candidate.isPothole {
            stats.potholesReported += 1
        }

        try context.save()
    }

    func savePrivacyFilteredSample(_ sample: LocationSample) throws {
        let context = ModelContext(container)
        let record = ReadingRecord(
            latitude: sample.latitude,
            longitude: sample.longitude,
            roughnessRMS: 0,
            speedKMH: sample.speedKmh,
            heading: sample.headingDegrees,
            gpsAccuracyM: sample.horizontalAccuracyMeters,
            isPothole: false,
            potholeMagnitude: nil,
            recordedAt: Date(timeIntervalSince1970: sample.timestamp),
            droppedByPrivacyZone: true
        )
        context.insert(record)
        try context.save()
    }

    func acceptedReadingCount() throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate { $0.droppedByPrivacyZone == false }
        )
        return try context.fetchCount(descriptor)
    }

    func privacyFilteredReadingCount() throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate { $0.droppedByPrivacyZone == true }
        )
        return try context.fetchCount(descriptor)
    }

    func deleteAllContributionData() throws {
        let context = ModelContext(container)

        for reading in try context.fetch(FetchDescriptor<ReadingRecord>()) {
            context.delete(reading)
        }
        for batch in try context.fetch(FetchDescriptor<UploadBatch>()) {
            context.delete(batch)
        }
        for stats in try context.fetch(FetchDescriptor<UserStats>()) {
            context.delete(stats)
        }
        for token in try context.fetch(FetchDescriptor<DeviceTokenRecord>()) {
            context.delete(token)
        }

        try context.save()
    }

    private func fetchOrCreateStats(in context: ModelContext) throws -> UserStats {
        var descriptor = FetchDescriptor<UserStats>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        descriptor.fetchLimit = 1

        if let stats = try context.fetch(descriptor).first {
            return stats
        }

        let stats = UserStats()
        context.insert(stats)
        return stats
    }
}
