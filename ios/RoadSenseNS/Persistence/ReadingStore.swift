import CoreLocation
import Foundation
import SwiftData

struct DriveSessionFinalizationSummary: Equatable {
    let sessionID: UUID
    let eligibleReadingCount: Int
    let trimmedReadingCount: Int
    let privacyFilteredReadingCount: Int
}

@MainActor
final class ReadingStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func ensureActiveDriveSession(for sample: LocationSample) throws -> UUID {
        let context = ModelContext(container)
        if let existing = try fetchActiveDriveSession(in: context) {
            return existing.id
        }

        let record = DriveSessionRecord(
            startedAt: Date(timeIntervalSince1970: sample.timestamp),
            startLatitude: sample.latitude,
            startLongitude: sample.longitude
        )
        context.insert(record)
        try context.save()
        return record.id
    }

    func activeDriveSessionID() throws -> UUID? {
        let context = ModelContext(container)
        return try fetchActiveDriveSession(in: context)?.id
    }

    func finalizeDriveSession(
        id: UUID,
        fallbackEndSample: LocationSample? = nil,
        now: Date = Date()
    ) throws -> DriveSessionFinalizationSummary? {
        let context = ModelContext(container)
        guard let session = try fetchDriveSession(id: id, in: context) else {
            return nil
        }

        let sessionReadings = try context.fetch(
            FetchDescriptor<ReadingRecord>(
                predicate: #Predicate { $0.driveSessionID == id },
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
            )
        )
        let privacyFilteredCount = sessionReadings.filter(\.droppedByPrivacyZone).count

        if session.isSealed {
            let eligibleCount = sessionReadings.filter { $0.isReadyForUpload }.count
            let trimmedCount = sessionReadings.filter {
                $0.droppedByPrivacyZone == false && $0.endpointTrimmedAt != nil
            }.count
            return DriveSessionFinalizationSummary(
                sessionID: id,
                eligibleReadingCount: eligibleCount,
                trimmedReadingCount: trimmedCount,
                privacyFilteredReadingCount: privacyFilteredCount
            )
        }

        let endSample = try resolveEndSample(for: id, fallback: fallbackEndSample, in: context)
        let endTimestamp = Date(timeIntervalSince1970: endSample.timestamp)
        session.endedAt = endTimestamp
        session.endLatitude = endSample.latitude
        session.endLongitude = endSample.longitude
        session.isSealed = true

        let endpoints = DriveSessionEndpoints(
            startedAt: session.startedAt,
            endedAt: endTimestamp,
            startLatitude: session.startLatitude,
            startLongitude: session.startLongitude,
            endLatitude: endSample.latitude,
            endLongitude: endSample.longitude
        )

        let acceptedReadings = sessionReadings.filter { $0.droppedByPrivacyZone == false }

        var eligibleCount = 0
        var trimmedCount = 0
        for reading in acceptedReadings {
            if DriveEndpointTrimmer.shouldTrim(
                readingRecordedAt: reading.recordedAt,
                latitude: reading.latitude,
                longitude: reading.longitude,
                session: endpoints
            ) {
                reading.endpointTrimmedAt = now
                reading.uploadReadyAt = nil
                trimmedCount += 1
            } else {
                reading.endpointTrimmedAt = nil
                reading.uploadReadyAt = now
                eligibleCount += 1
            }
        }

        try context.save()

        return DriveSessionFinalizationSummary(
            sessionID: id,
            eligibleReadingCount: eligibleCount,
            trimmedReadingCount: trimmedCount,
            privacyFilteredReadingCount: privacyFilteredCount
        )
    }

    func finalizeOpenDriveSessions(now: Date = Date()) throws -> [DriveSessionFinalizationSummary] {
        let context = ModelContext(container)
        let sessions = try context.fetch(
            FetchDescriptor<DriveSessionRecord>(
                predicate: #Predicate { $0.isSealed == false },
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
        )

        var summaries: [DriveSessionFinalizationSummary] = []
        for session in sessions {
            if let summary = try finalizeDriveSession(id: session.id, now: now) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    func saveAccepted(
        _ candidate: PersistedReadingCandidate,
        driveSessionID: UUID? = nil
    ) throws {
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
            recordedAt: candidate.recordedAt,
            driveSessionID: driveSessionID,
            uploadReadyAt: driveSessionID == nil ? candidate.recordedAt : nil
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

    func savePrivacyFilteredSample(
        _ sample: LocationSample,
        driveSessionID: UUID? = nil
    ) throws {
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
            driveSessionID: driveSessionID,
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

    func pendingUploadCoordinates(limit: Int = 500) throws -> [CLLocationCoordinate2D] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate { $0.uploadedAt == nil },
            sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
        )
        let readings = try context.fetch(descriptor)
            .filter { $0.isReadyForUpload }
            .prefix(max(limit, 0))

        return readings.map { (record: ReadingRecord) in
            CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude)
        }
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
        for session in try context.fetch(FetchDescriptor<DriveSessionRecord>()) {
            context.delete(session)
        }

        try context.save()
    }

    private func fetchActiveDriveSession(in context: ModelContext) throws -> DriveSessionRecord? {
        var descriptor = FetchDescriptor<DriveSessionRecord>(
            predicate: #Predicate { $0.isSealed == false },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchDriveSession(id: UUID, in context: ModelContext) throws -> DriveSessionRecord? {
        var descriptor = FetchDescriptor<DriveSessionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func resolveEndSample(
        for sessionID: UUID,
        fallback: LocationSample?,
        in context: ModelContext
    ) throws -> LocationSample {
        let readings = try context.fetch(
            FetchDescriptor<ReadingRecord>(
                predicate: #Predicate { $0.driveSessionID == sessionID },
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
            )
        )

        let fallbackCandidate = fallback.map {
            LocationSample(
                timestamp: $0.timestamp,
                latitude: $0.latitude,
                longitude: $0.longitude,
                horizontalAccuracyMeters: $0.horizontalAccuracyMeters,
                speedKmh: $0.speedKmh,
                headingDegrees: $0.headingDegrees
            )
        }

        let readingCandidate = readings.last.map { (record: ReadingRecord) in
            LocationSample(
                timestamp: record.recordedAt.timeIntervalSince1970,
                latitude: record.latitude,
                longitude: record.longitude,
                horizontalAccuracyMeters: record.gpsAccuracyM,
                speedKmh: record.speedKMH,
                headingDegrees: record.heading
            )
        }

        if let fallbackCandidate, let readingCandidate {
            return fallbackCandidate.timestamp >= readingCandidate.timestamp ? fallbackCandidate : readingCandidate
        }

        if let fallbackCandidate {
            return fallbackCandidate
        }

        if let readingCandidate {
            return readingCandidate
        }

        guard let session = try fetchDriveSession(id: sessionID, in: context) else {
            fatalError("Missing drive session while resolving end sample")
        }

        return LocationSample(
            timestamp: session.startedAt.timeIntervalSince1970,
            latitude: session.startLatitude,
            longitude: session.startLongitude,
            horizontalAccuracyMeters: 0,
            speedKmh: 0,
            headingDegrees: 0
        )
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
