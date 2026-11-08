import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Retention policy")
struct RetentionPolicyTests {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("prunes uploaded readings older than 30 days")
    func prunesOldUploadedReadings() {
        let staleUploaded = QueueReadingRecord(uploadedAt: now.addingTimeInterval(-31 * day))
        let freshUploaded = QueueReadingRecord(uploadedAt: now.addingTimeInterval(-5 * day))
        let pending = QueueReadingRecord(uploadBatchID: nil, uploadedAt: nil)

        let pruned = RetentionPolicy.pruneUploadedReadings(
            [staleUploaded, freshUploaded, pending],
            now: now
        )

        #expect(pruned.contains(staleUploaded) == false)
        #expect(pruned.contains(freshUploaded))
        #expect(pruned.contains(pending))
    }

    @Test("never prunes a reading still waiting to upload")
    func keepsPendingReadings() {
        #expect(RetentionPolicy.shouldPruneReading(
            recordedAt: now.addingTimeInterval(-90 * day),
            uploadedAt: nil,
            endpointTrimmedAt: nil,
            droppedByPrivacyZone: false,
            now: now
        ) == false)
    }

    @Test("prunes uploaded readings by upload time")
    func prunesByUploadTime() {
        #expect(RetentionPolicy.shouldPruneReading(
            recordedAt: now.addingTimeInterval(-40 * day),
            uploadedAt: now.addingTimeInterval(-31 * day),
            endpointTrimmedAt: nil,
            droppedByPrivacyZone: false,
            now: now
        ))
        #expect(RetentionPolicy.shouldPruneReading(
            recordedAt: now.addingTimeInterval(-40 * day),
            uploadedAt: now.addingTimeInterval(-2 * day),
            endpointTrimmedAt: nil,
            droppedByPrivacyZone: false,
            now: now
        ) == false)
    }

    @Test("prunes old privacy-zone and endpoint-trimmed rows, keeps recent ones")
    func prunesNeverUploadableRows() {
        let old = now.addingTimeInterval(-31 * day)
        let recent = now.addingTimeInterval(-1 * day)

        #expect(RetentionPolicy.shouldPruneReading(
            recordedAt: old, uploadedAt: nil, endpointTrimmedAt: nil, droppedByPrivacyZone: true, now: now
        ))
        #expect(RetentionPolicy.shouldPruneReading(
            recordedAt: old, uploadedAt: nil, endpointTrimmedAt: old, droppedByPrivacyZone: false, now: now
        ))
        #expect(RetentionPolicy.shouldPruneReading(
            recordedAt: recent, uploadedAt: nil, endpointTrimmedAt: nil, droppedByPrivacyZone: true, now: now
        ) == false)
    }

    @Test("prunes only terminal batches past the window")
    func prunesTerminalBatches() {
        let old = now.addingTimeInterval(-31 * day)
        #expect(RetentionPolicy.shouldPruneBatch(status: .succeeded, createdAt: old, lastAttemptAt: old, now: now))
        #expect(RetentionPolicy.shouldPruneBatch(status: .failedPermanent, createdAt: old, lastAttemptAt: nil, now: now))
        #expect(RetentionPolicy.shouldPruneBatch(status: .pending, createdAt: old, lastAttemptAt: old, now: now) == false)
        #expect(RetentionPolicy.shouldPruneBatch(status: .inFlight, createdAt: old, lastAttemptAt: old, now: now) == false)
        #expect(RetentionPolicy.shouldPruneBatch(
            status: .succeeded,
            createdAt: old,
            lastAttemptAt: now.addingTimeInterval(-day),
            now: now
        ) == false)
    }

    @Test("prunes empty sealed drives past the window")
    func prunesEmptyDrives() {
        let old = now.addingTimeInterval(-31 * day)
        #expect(RetentionPolicy.shouldPruneDriveSession(
            isSealed: true, startedAt: old, endedAt: old, remainingReadingCount: 0, now: now
        ))
        #expect(RetentionPolicy.shouldPruneDriveSession(
            isSealed: true, startedAt: old, endedAt: old, remainingReadingCount: 3, now: now
        ) == false)
        #expect(RetentionPolicy.shouldPruneDriveSession(
            isSealed: false, startedAt: old, endedAt: nil, remainingReadingCount: 0, now: now
        ) == false)
    }

    @Test("sweep throttle runs once per window")
    func sweepThrottle() {
        let throttle = RetentionSweepThrottle(minimumInterval: 60)
        let neverRun: Date? = nil
        #expect(throttle.shouldRun(lastRunAt: neverRun, now: now))
        #expect(throttle.shouldRun(lastRunAt: now.addingTimeInterval(-30), now: now) == false)
        #expect(throttle.shouldRun(lastRunAt: now.addingTimeInterval(-60), now: now))
        #expect(throttle.shouldRun(lastRunAt: now.addingTimeInterval(600), now: now))
    }
}
