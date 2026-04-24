import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class PotholePhotoStoreTests: XCTestCase {
    func testQueuePreparedReportCreatesPendingMetadataRow() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholePhotoStore(container: container)
        let fileURL = try temporaryPhotoURL()
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        let report = try store.queuePreparedReport(
            segmentID: UUID(),
            photoFileURL: fileURL,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 6,
            capturedAt: Date(timeIntervalSince1970: 1_713_000_000),
            byteSize: 3,
            sha256Hex: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(report.uploadState, .pendingMetadata)

        let context = ModelContext(container)
        let reports = try context.fetch(FetchDescriptor<PotholeReportRecord>())
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.photoFilePath, fileURL.path)
    }

    func testApplyUploadSuccessMovesReportToPendingModerationAndDeletesFile() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholePhotoStore(container: container)
        let fileURL = try temporaryPhotoURL()
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        let report = try store.queuePreparedReport(
            segmentID: nil,
            photoFileURL: fileURL,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 6,
            capturedAt: Date(timeIntervalSince1970: 1_713_000_000),
            byteSize: 3,
            sha256Hex: String(repeating: "b", count: 64)
        )

        try store.applyUploadSuccess(
            id: report.id,
            expectedObjectPath: "pending/\(report.id.uuidString.lowercased()).jpg",
            requestID: "req-photo-1"
        )

        let context = ModelContext(container)
        let persisted = try context.fetch(FetchDescriptor<PotholeReportRecord>())
        XCTAssertEqual(persisted.first?.uploadState, .pendingModeration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try store.pendingCount(), 1)
    }

    func testRetryFailedReportsResetsPermanentFailures() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholePhotoStore(container: container)
        let fileURL = try temporaryPhotoURL()
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        let context = ModelContext(container)
        let reportID = UUID()
        context.insert(
            PotholeReportRecord(
                id: reportID,
                segmentID: nil,
                photoFilePath: fileURL.path,
                latitude: 44.6488,
                longitude: -63.5752,
                accuracyM: 6,
                capturedAt: Date(timeIntervalSince1970: 1_713_000_000),
                uploadState: .failedPermanent,
                uploadAttemptCount: 5,
                lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_060),
                nextAttemptAt: Date(timeIntervalSince1970: 1_713_000_120),
                byteSize: 3,
                sha256Hex: String(repeating: "c", count: 64),
                lastHTTPStatusCode: 400,
                lastRequestID: "req-photo-2"
            )
        )
        try context.save()

        try store.retryFailedReports()

        let updatedContext = ModelContext(container)
        let reports = try updatedContext.fetch(FetchDescriptor<PotholeReportRecord>())
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.uploadState, .pendingMetadata)
        XCTAssertEqual(reports.first?.uploadAttemptCount, 0)
        XCTAssertNil(reports.first?.lastAttemptAt)
        XCTAssertNil(reports.first?.nextAttemptAt)
        XCTAssertNil(reports.first?.lastHTTPStatusCode)
        XCTAssertNil(reports.first?.lastRequestID)
    }

    private func temporaryPhotoURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url.appendingPathComponent("photo.jpg")
    }
}
