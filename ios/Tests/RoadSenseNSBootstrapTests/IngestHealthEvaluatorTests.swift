import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Ingest health evaluator")
struct IngestHealthEvaluatorTests {
    @Test("stays healthy when reject ratio is below threshold")
    func staysHealthyBelowThreshold() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries = [
            UploadBatchDiagnosticEntry(
                recordedAt: now.addingTimeInterval(-60),
                acceptedCount: 90,
                rejectedCount: 10,
                rejectedReasons: ["low_quality": 10]
            )
        ]

        let state = IngestHealthEvaluator.evaluate(entries: entries, now: now)
        #expect(state == .healthy)
    }

    @Test("stays healthy when the top reason is not actionable")
    func staysHealthyForNonActionableReason() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries = [
            UploadBatchDiagnosticEntry(
                recordedAt: now.addingTimeInterval(-60),
                acceptedCount: 10,
                rejectedCount: 30,
                rejectedReasons: ["future_timestamp": 30]
            )
        ]

        let state = IngestHealthEvaluator.evaluate(entries: entries, now: now)
        #expect(state == .healthy)
    }

    @Test("degrades when 24 hour rejects exceed 20 percent for an actionable reason")
    func degradesForPersistentActionableReason() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries = [
            UploadBatchDiagnosticEntry(
                recordedAt: now.addingTimeInterval(-60),
                acceptedCount: 10,
                rejectedCount: 30,
                rejectedReasons: ["low_quality": 30]
            ),
            UploadBatchDiagnosticEntry(
                recordedAt: now.addingTimeInterval(-120),
                acceptedCount: 5,
                rejectedCount: 10,
                rejectedReasons: ["stale_timestamp": 10]
            )
        ]

        let state = IngestHealthEvaluator.evaluate(entries: entries, now: now)

        guard case let .degraded(reason, ratio) = state else {
            Issue.record("Expected degraded ingest health")
            return
        }

        #expect(reason == "low_quality")
        #expect(ratio > 0.2)
    }

    @Test("ignores entries older than 24 hours")
    func ignoresOldEntries() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries = [
            UploadBatchDiagnosticEntry(
                recordedAt: now.addingTimeInterval(-26 * 60 * 60),
                acceptedCount: 0,
                rejectedCount: 100,
                rejectedReasons: ["low_quality": 100]
            )
        ]

        let state = IngestHealthEvaluator.evaluate(entries: entries, now: now)
        #expect(state == .healthy)
    }
}
