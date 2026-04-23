import Foundation
import SwiftData

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
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }

        report.uploadState = .pendingModeration
        report.expectedObjectPath = expectedObjectPath ?? report.expectedObjectPath
        report.lastRequestID = requestID
        report.lastAttemptAt = now
        report.nextAttemptAt = nil
        try context.save()
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
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }

        context.delete(report)
        try context.save()
    }

    func pendingCount() throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PotholeReportRecord>(
            predicate: #Predicate { $0.uploadStateRawValue == "pending_metadata" }
        )
        return try context.fetchCount(descriptor)
    }

    private func fetchRecord(id: UUID, in context: ModelContext) throws -> PotholeReportRecord? {
        var descriptor = FetchDescriptor<PotholeReportRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
