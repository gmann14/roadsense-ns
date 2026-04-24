import Foundation
import SwiftData

struct PotholePhotoStatusSummary: Equatable {
    let pendingCount: Int
    let failedPermanentCount: Int
    let nextRetryAt: Date?
    let lastSuccessfulUploadAt: Date?

    static let empty = PotholePhotoStatusSummary(
        pendingCount: 0,
        failedPermanentCount: 0,
        nextRetryAt: nil,
        lastSuccessfulUploadAt: nil
    )
}

struct FailedPotholePhotoSummary: Identifiable, Equatable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let capturedAt: Date
    let lastHTTPStatusCode: Int?
}

@MainActor
final class PotholePhotoStore {
    private let container: ModelContainer
    private let fileManager: FileManager

    enum DrainDecision {
        case ready(PotholeReportRecord)
        case blocked(nextAttemptAt: Date)
        case none
    }

    init(
        container: ModelContainer,
        fileManager: FileManager = .default
    ) {
        self.container = container
        self.fileManager = fileManager
    }

    func queuePreparedReport(
        segmentID: UUID?,
        photoFileURL: URL,
        latitude: Double,
        longitude: Double,
        accuracyM: Double,
        capturedAt: Date,
        byteSize: Int,
        sha256Hex: String
    ) throws -> PotholeReportRecord {
        let context = ModelContext(container)
        let record = PotholeReportRecord(
            segmentID: segmentID,
            photoFilePath: photoFileURL.path,
            latitude: latitude,
            longitude: longitude,
            accuracyM: accuracyM,
            capturedAt: capturedAt,
            uploadState: .pendingMetadata,
            byteSize: byteSize,
            sha256Hex: sha256Hex
        )
        context.insert(record)
        try context.save()
        return record
    }

    func prepareNextReport(now: Date = Date()) throws -> DrainDecision {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PotholeReportRecord>(
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )

        for report in try context.fetch(descriptor) {
            switch report.uploadState {
            case .pendingModeration, .failedPermanent:
                continue
            case .pendingMetadata:
                if let nextAttemptAt = report.nextAttemptAt, nextAttemptAt > now {
                    return .blocked(nextAttemptAt: nextAttemptAt)
                }
                return .ready(report)
            }
        }

        return .none
    }

    func applyUploadSuccess(
        id: UUID,
        expectedObjectPath: String?,
        requestID: String?,
        now: Date = Date()
    ) throws {
        let context = ModelContext(container)
        guard let report = try fetchRecord(id: id, in: context) else {
            return
        }

        let fileURL = report.photoFileURL
        report.uploadState = .pendingModeration
        report.expectedObjectPath = expectedObjectPath ?? report.expectedObjectPath
        report.lastRequestID = requestID
        report.lastAttemptAt = now
        report.nextAttemptAt = nil
        try context.save()

        removeFileIfPresent(at: fileURL)
    }

    func applyUploadFailure(
        id: UUID,
        disposition: UploadDisposition,
        attemptResult: UploadAttemptResult,
        requestID: String?,
        now: Date = Date()
    ) throws {
        let context = ModelContext(container)
        guard let report = try fetchRecord(id: id, in: context) else {
            return
        }

        report.uploadAttemptCount += 1
        report.lastAttemptAt = now
        report.lastRequestID = requestID
        if case let .http(statusCode, _) = attemptResult {
            report.lastHTTPStatusCode = statusCode
        }

        switch disposition {
        case .succeeded:
            report.uploadState = .pendingModeration
            report.nextAttemptAt = nil
        case let .retry(afterSeconds):
            report.uploadState = .pendingMetadata
            report.nextAttemptAt = now.addingTimeInterval(afterSeconds)
        case .failedPermanent:
            report.uploadState = .failedPermanent
            report.nextAttemptAt = nil
        }

        try context.save()
    }

    func deleteReport(id: UUID) throws {
        let context = ModelContext(container)
        guard let report = try fetchRecord(id: id, in: context) else {
            return
        }

        let fileURL = report.photoFileURL
        context.delete(report)
        try context.save()

        removeFileIfPresent(at: fileURL)
    }

    func pendingCount() throws -> Int {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<PotholeReportRecord>())
            .filter { report in
                report.uploadState == .pendingMetadata || report.uploadState == .pendingModeration
            }
            .count
    }

    func statusSummary(now: Date = Date()) throws -> PotholePhotoStatusSummary {
        let context = ModelContext(container)
        let reports = try context.fetch(FetchDescriptor<PotholeReportRecord>())

        let pendingCount = reports.filter { report in
            report.uploadState == .pendingMetadata || report.uploadState == .pendingModeration
        }.count
        let failedPermanentCount = reports.filter { $0.uploadState == .failedPermanent }.count
        let nextRetryAt = reports
            .filter { $0.uploadState == .pendingMetadata }
            .compactMap(\.nextAttemptAt)
            .filter { $0 > now }
            .min()
        let lastSuccessfulUploadAt = reports
            .filter { $0.uploadState == .pendingModeration }
            .compactMap(\.lastAttemptAt)
            .max()

        return PotholePhotoStatusSummary(
            pendingCount: pendingCount,
            failedPermanentCount: failedPermanentCount,
            nextRetryAt: nextRetryAt,
            lastSuccessfulUploadAt: lastSuccessfulUploadAt
        )
    }

    func failedPermanentReports(limit: Int = 10) throws -> [FailedPotholePhotoSummary] {
        let context = ModelContext(container)
        let reports = try context.fetch(FetchDescriptor<PotholeReportRecord>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        ))

        return reports
            .filter { $0.uploadState == .failedPermanent }
            .prefix(max(limit, 0))
            .map { report in
                FailedPotholePhotoSummary(
                    id: report.id,
                    latitude: report.latitude,
                    longitude: report.longitude,
                    capturedAt: report.capturedAt,
                    lastHTTPStatusCode: report.lastHTTPStatusCode
                )
            }
    }

    func retryFailedReports(ids: [UUID]? = nil) throws {
        let context = ModelContext(container)
        let retryIDs = ids.map(Set.init)
        let reports = try context.fetch(FetchDescriptor<PotholeReportRecord>())
        var didChange = false

        for report in reports where report.uploadState == .failedPermanent {
            guard retryIDs?.contains(report.id) ?? true else {
                continue
            }

            report.uploadState = .pendingMetadata
            report.uploadAttemptCount = 0
            report.lastAttemptAt = nil
            report.nextAttemptAt = nil
            report.lastHTTPStatusCode = nil
            report.lastRequestID = nil
            didChange = true
        }

        if didChange {
            try context.save()
        }
    }

    func deleteAllReports() throws {
        let context = ModelContext(container)
        let reports = try context.fetch(FetchDescriptor<PotholeReportRecord>())
        let fileURLs = reports.map(\.photoFileURL)

        for report in reports {
            context.delete(report)
        }

        if !reports.isEmpty {
            try context.save()
        }

        for fileURL in fileURLs {
            removeFileIfPresent(at: fileURL)
        }
    }

    private func fetchRecord(id: UUID, in context: ModelContext) throws -> PotholeReportRecord? {
        var descriptor = FetchDescriptor<PotholeReportRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func removeFileIfPresent(at fileURL: URL) {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        try? fileManager.removeItem(at: fileURL)
    }
}
