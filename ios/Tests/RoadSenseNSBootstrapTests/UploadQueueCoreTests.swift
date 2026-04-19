import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Upload queue core")
struct UploadQueueCoreTests {
    @Test("creates a new batch from at most 1000 pending readings")
    func createsBatchWithLimit() {
        let now = Date(timeIntervalSince1970: 1_000)
        let readings = (0..<1_200).map { _ in QueueReadingRecord() }

        let decision = UploadQueueCore.prepareNextBatch(
            pendingReadings: readings,
            existingBatch: nil,
            now: now,
            makeBatchID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )

        guard case let .ready(batch, updatedReadings) = decision else {
            Issue.record("Expected a ready batch")
            return
        }

        let assignedCount = updatedReadings.filter { $0.uploadBatchID == batch.id }.count
        let unassignedCount = updatedReadings.filter { $0.uploadBatchID == nil }.count

        #expect(batch.id.uuidString == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(batch.readingCount == 1_000)
        #expect(assignedCount == 1_000)
        #expect(unassignedCount == 200)
    }

    @Test("reuses an existing retry batch instead of minting a new id")
    func reusesExistingBatch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let existingBatch = QueueUploadBatch(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: now.addingTimeInterval(-60),
            attemptCount: 1,
            lastAttemptAt: now.addingTimeInterval(-30),
            status: .pending,
            readingCount: 10
        )

        let decision = UploadQueueCore.prepareNextBatch(
            pendingReadings: (0..<10).map { _ in QueueReadingRecord(uploadBatchID: existingBatch.id) },
            existingBatch: existingBatch,
            now: now,
            makeBatchID: { UUID() }
        )

        guard case let .ready(batch, _) = decision else {
            Issue.record("Expected reused batch")
            return
        }

        #expect(batch.id == existingBatch.id)
    }

    @Test("successful upload marks the batch and attached readings complete")
    func successMarksUploadComplete() {
        let now = Date(timeIntervalSince1970: 2_000)
        let batchID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let batch = QueueUploadBatch(
            id: batchID,
            createdAt: now.addingTimeInterval(-60),
            attemptCount: 1,
            lastAttemptAt: now.addingTimeInterval(-30),
            status: .inFlight,
            readingCount: 2
        )
        let readings = [
            QueueReadingRecord(uploadBatchID: batchID),
            QueueReadingRecord(uploadBatchID: batchID),
        ]

        let outcome = UploadQueueCore.applySuccess(
            batch: batch,
            readings: readings,
            result: UploadServerResult(
                acceptedCount: 2,
                rejectedCount: 0,
                rejectedReasons: [:],
                wasDuplicateOnResubmit: false
            ),
            now: now
        )

        #expect(outcome.batch.status == .succeeded)
        #expect(outcome.batch.acceptedCount == 2)
        #expect(outcome.readings.allSatisfy { $0.uploadedAt == now })
    }

    @Test("permanent failure updates the batch state and keeps first error")
    func permanentFailureUpdatesState() {
        let now = Date(timeIntervalSince1970: 3_000)
        let batch = QueueUploadBatch(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: now.addingTimeInterval(-60),
            attemptCount: 4,
            lastAttemptAt: now.addingTimeInterval(-30),
            status: .inFlight,
            readingCount: 10
        )

        let updated = UploadQueueCore.applyFailure(
            batch: batch,
            disposition: .failedPermanent,
            errorMessage: "validation_failed",
            now: now
        )

        #expect(updated.status == .failedPermanent)
        #expect(updated.firstErrorMessage == "validation_failed")
        #expect(updated.attemptCount == 5)
    }
}
