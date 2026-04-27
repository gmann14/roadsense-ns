import CoreLocation
import Foundation
import SwiftData

struct DriveSessionFinalizationSummary: Equatable {
    let sessionID: UUID
    let eligibleReadingCount: Int
    let trimmedReadingCount: Int
    let privacyFilteredReadingCount: Int
}

struct DriveSessionFragmentRepairSummary: Equatable {
    let fragmentedGroupCount: Int
    let recoveredEligibleReadingCount: Int
    let eligibleReadingCount: Int
    let trimmedReadingCount: Int

    static let empty = DriveSessionFragmentRepairSummary(
        fragmentedGroupCount: 0,
        recoveredEligibleReadingCount: 0,
        eligibleReadingCount: 0,
        trimmedReadingCount: 0
    )
}

struct DriveSummary: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let isSealed: Bool
    let acceptedReadingCount: Int
    let privacyFilteredReadingCount: Int
    let potholeCount: Int
    let distanceKm: Double
    let bbox: DriveBoundingBox?

    var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    var hasOnlyPrivacyFilteredData: Bool {
        acceptedReadingCount == 0 && privacyFilteredReadingCount > 0
    }
}

struct DriveBoundingBox: Equatable {
    let minLatitude: Double
    let minLongitude: Double
    let maxLatitude: Double
    let maxLongitude: Double
}

enum DriveStore {
    static let earthRadiusMeters: Double = 6_371_000

    @MainActor
    static func makeSummary(session: DriveSessionRecord, readings: [ReadingRecord]) -> DriveSummary {
        let accepted = readings.filter { $0.droppedByPrivacyZone == false }
        let privacyFiltered = readings.count - accepted.count
        let potholes = accepted.filter { $0.isPothole }.count

        let distanceKm = haversineDistanceKm(coordinates: accepted.map { ($0.latitude, $0.longitude) })
        let bbox = boundingBox(coordinates: accepted.map { ($0.latitude, $0.longitude) })
            ?? boundingBox(from: session)

        return DriveSummary(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            isSealed: session.isSealed,
            acceptedReadingCount: accepted.count,
            privacyFilteredReadingCount: privacyFiltered,
            potholeCount: potholes,
            distanceKm: distanceKm,
            bbox: bbox
        )
    }

    static func haversineDistanceKm(coordinates: [(Double, Double)]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        var total: Double = 0
        for index in 1..<coordinates.count {
            total += haversineMeters(
                latA: coordinates[index - 1].0,
                lngA: coordinates[index - 1].1,
                latB: coordinates[index].0,
                lngB: coordinates[index].1
            )
        }
        return total / 1_000.0
    }

    static func haversineMeters(latA: Double, lngA: Double, latB: Double, lngB: Double) -> Double {
        let dLat = (latB - latA) * .pi / 180
        let dLng = (lngB - lngA) * .pi / 180
        let lat1 = latA * .pi / 180
        let lat2 = latB * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLng / 2) * sin(dLng / 2) * cos(lat1) * cos(lat2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }

    static func boundingBox(coordinates: [(Double, Double)]) -> DriveBoundingBox? {
        guard !coordinates.isEmpty else { return nil }
        var minLat = coordinates[0].0
        var maxLat = coordinates[0].0
        var minLng = coordinates[0].1
        var maxLng = coordinates[0].1
        for (lat, lng) in coordinates.dropFirst() {
            if lat < minLat { minLat = lat }
            if lat > maxLat { maxLat = lat }
            if lng < minLng { minLng = lng }
            if lng > maxLng { maxLng = lng }
        }
        return DriveBoundingBox(
            minLatitude: minLat,
            minLongitude: minLng,
            maxLatitude: maxLat,
            maxLongitude: maxLng
        )
    }

    @MainActor
    static func boundingBox(from session: DriveSessionRecord) -> DriveBoundingBox? {
        let endLatitude = session.endLatitude ?? session.startLatitude
        let endLongitude = session.endLongitude ?? session.startLongitude
        return DriveBoundingBox(
            minLatitude: min(session.startLatitude, endLatitude),
            minLongitude: min(session.startLongitude, endLongitude),
            maxLatitude: max(session.startLatitude, endLatitude),
            maxLongitude: max(session.startLongitude, endLongitude)
        )
    }
}

struct LocalDriveOverlayPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let roughnessCategory: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func category(for roughnessRMS: Double) -> String {
        if roughnessRMS < 0.05 { return "smooth" }
        if roughnessRMS < 0.09 { return "fair" }
        if roughnessRMS < 0.14 { return "rough" }
        return "very_rough"
    }
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

    func repairFragmentedDriveSessions(
        now: Date = Date(),
        maximumGapSeconds: TimeInterval = 60
    ) throws -> DriveSessionFragmentRepairSummary {
        let context = ModelContext(container)
        let sessions = try context.fetch(
            FetchDescriptor<DriveSessionRecord>(
                predicate: #Predicate { $0.isSealed == true },
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
        ).filter { $0.endedAt != nil && $0.endLatitude != nil && $0.endLongitude != nil }

        let fragmentedGroups = groupedFragmentedSessions(
            from: sessions,
            maximumGapSeconds: maximumGapSeconds
        )
        guard !fragmentedGroups.isEmpty else {
            return .empty
        }

        let readings = try context.fetch(
            FetchDescriptor<ReadingRecord>(
                predicate: #Predicate { $0.uploadedAt == nil }
            )
        )

        var recoveredEligibleCount = 0
        var eligibleCount = 0
        var trimmedCount = 0
        var didMutate = false

        for group in fragmentedGroups {
            let sessionIDs = Set(group.map(\.id))
            let endpoints = DriveSessionEndpoints(
                startedAt: group[0].startedAt,
                endedAt: group[group.count - 1].endedAt ?? group[group.count - 1].startedAt,
                startLatitude: group[0].startLatitude,
                startLongitude: group[0].startLongitude,
                endLatitude: group[group.count - 1].endLatitude ?? group[group.count - 1].startLatitude,
                endLongitude: group[group.count - 1].endLongitude ?? group[group.count - 1].startLongitude
            )

            for reading in readings where reading.droppedByPrivacyZone == false {
                guard let driveSessionID = reading.driveSessionID,
                      sessionIDs.contains(driveSessionID) else {
                    continue
                }

                if DriveEndpointTrimmer.shouldTrim(
                    readingRecordedAt: reading.recordedAt,
                    latitude: reading.latitude,
                    longitude: reading.longitude,
                    session: endpoints
                ) {
                    trimmedCount += 1
                    if reading.endpointTrimmedAt == nil
                        || reading.uploadReadyAt != nil
                        || reading.uploadBatchID != nil {
                        didMutate = true
                    }
                    reading.endpointTrimmedAt = now
                    reading.uploadReadyAt = nil
                    reading.uploadBatchID = nil
                } else {
                    eligibleCount += 1
                    if reading.endpointTrimmedAt != nil {
                        recoveredEligibleCount += 1
                    }
                    if reading.endpointTrimmedAt != nil
                        || reading.uploadReadyAt == nil
                        || reading.uploadBatchID != nil {
                        didMutate = true
                    }
                    reading.endpointTrimmedAt = nil
                    reading.uploadReadyAt = now
                    reading.uploadBatchID = nil
                }
            }
        }

        if didMutate {
            try context.save()
        }

        return DriveSessionFragmentRepairSummary(
            fragmentedGroupCount: fragmentedGroups.count,
            recoveredEligibleReadingCount: recoveredEligibleCount,
            eligibleReadingCount: eligibleCount,
            trimmedReadingCount: trimmedCount
        )
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

    func localDriveOverlayPoints(limit: Int = 500) throws -> [LocalDriveOverlayPoint] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate {
                $0.uploadedAt == nil
                    && $0.droppedByPrivacyZone == false
                    && $0.endpointTrimmedAt == nil
            },
            sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
        )
        let readings = try context.fetch(descriptor).prefix(max(limit, 0))

        return readings.map { record in
            LocalDriveOverlayPoint(
                latitude: record.latitude,
                longitude: record.longitude,
                roughnessCategory: LocalDriveOverlayPoint.category(for: record.roughnessRMS)
            )
        }
    }

    private func groupedFragmentedSessions(
        from sessions: [DriveSessionRecord],
        maximumGapSeconds: TimeInterval
    ) -> [[DriveSessionRecord]] {
        guard !sessions.isEmpty else {
            return []
        }

        var groups: [[DriveSessionRecord]] = []
        var currentGroup: [DriveSessionRecord] = []

        for session in sessions {
            guard session.endedAt != nil else {
                continue
            }

            if let previous = currentGroup.last,
               let previousEndedAt = previous.endedAt,
               session.startedAt.timeIntervalSince(previousEndedAt) <= maximumGapSeconds {
                currentGroup.append(session)
            } else {
                if currentGroup.count > 1 {
                    groups.append(currentGroup)
                }
                currentGroup = [session]
            }

        }

        if currentGroup.count > 1 {
            groups.append(currentGroup)
        }

        return groups
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

    func recentDriveSummaries(limit: Int = 50) throws -> [DriveSummary] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<DriveSessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 0)
        let sessions = try context.fetch(descriptor)
        guard !sessions.isEmpty else { return [] }

        let sessionIDs = Set(sessions.map(\.id))
        let readings = try context.fetch(
            FetchDescriptor<ReadingRecord>(
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
            )
        ).filter { reading in
            guard let id = reading.driveSessionID else { return false }
            return sessionIDs.contains(id)
        }

        var grouped: [UUID: [ReadingRecord]] = [:]
        for reading in readings {
            guard let id = reading.driveSessionID else { continue }
            grouped[id, default: []].append(reading)
        }

        return sessions.map { session in
            DriveStore.makeSummary(session: session, readings: grouped[session.id] ?? [])
        }
    }

    func deleteDriveSession(id: UUID) throws {
        let context = ModelContext(container)
        let readings = try context.fetch(
            FetchDescriptor<ReadingRecord>(
                predicate: #Predicate { $0.driveSessionID == id }
            )
        )
        for reading in readings {
            context.delete(reading)
        }
        if let session = try fetchDriveSession(id: id, in: context) {
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
