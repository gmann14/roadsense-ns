import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Retention policy")
struct RetentionPolicyTests {
    @Test("prunes uploaded readings older than 30 days")
    func prunesOldUploadedReadings() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let staleUploaded = QueueReadingRecord(uploadedAt: now.addingTimeInterval(-31 * 24 * 60 * 60))
        let freshUploaded = QueueReadingRecord(uploadedAt: now.addingTimeInterval(-5 * 24 * 60 * 60))
        let pending = QueueReadingRecord(uploadBatchID: nil, uploadedAt: nil)

        let pruned = RetentionPolicy.pruneUploadedReadings(
            [staleUploaded, freshUploaded, pending],
            now: now
        )

        #expect(pruned.contains(staleUploaded) == false)
        #expect(pruned.contains(freshUploaded))
        #expect(pruned.contains(pending))
    }
}
