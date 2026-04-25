import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class PotholeActionStoreTests: XCTestCase {
    func testQueueManualReportDedupesNearbyTapInsideUndoWindow() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let firstSample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 50,
            headingDegrees: 180
        )
        let secondSample = LocationSample(
            timestamp: 1_713_000_002.0,
            latitude: 44.64882,
            longitude: -63.57522,
            horizontalAccuracyMeters: 5,
            speedKmh: 50,
            headingDegrees: 180
        )

        let first = try store.queueManualReport(
            sample: firstSample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )
        let second = try store.queueManualReport(
            sample: secondSample,
            now: Date(timeIntervalSince1970: 1_713_000_002.0)
        )

        XCTAssertEqual(first.id, second.id)

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.uploadState, .pendingUndo)
    }

    func testPromoteExpiredPendingUndoActionsMovesEligibleActionsToPendingUpload() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 50,
            headingDegrees: 180
        )

        let record = try store.queueManualReport(
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )

        let promoted = try store.promoteExpiredPendingUndoActions(
            now: Date(timeIntervalSince1970: 1_713_000_006.0)
        )

        XCTAssertEqual(promoted, 1)

        let context = ModelContext(container)
        let saved = try context.fetch(FetchDescriptor<PotholeActionRecord>())
            .first(where: { $0.id == record.id })
        XCTAssertEqual(saved?.uploadState, .pendingUpload)
        XCTAssertNil(saved?.undoExpiresAt)
    }

    func testManualReportStatsReflectPendingUndoAndPersistAfterPromotion() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let statsStore = UserStatsStore(container: container)
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 50,
            headingDegrees: 180
        )

        let record = try store.queueManualReport(
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )

        XCTAssertEqual(try statsStore.summary().potholesReported, 1)

        _ = try store.promoteExpiredPendingUndoActions(
            now: Date(timeIntervalSince1970: 1_713_000_006.0)
        )

        XCTAssertEqual(try statsStore.summary().potholesReported, 1)

        try store.applyUploadSuccess(id: record.id)

        XCTAssertEqual(try statsStore.summary().potholesReported, 1)
    }

    func testDiscardPendingUndoRemovesTemporaryStatsCount() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let statsStore = UserStatsStore(container: container)
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 50,
            headingDegrees: 180
        )

        let record = try store.queueManualReport(
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )

        XCTAssertEqual(try statsStore.summary().potholesReported, 1)

        try store.discard(
            id: record.id,
            now: Date(timeIntervalSince1970: 1_713_000_001.0)
        )

        XCTAssertEqual(try statsStore.summary().potholesReported, 0)
    }

    func testReconcileManualReportStatsRecoversCommittedLocalActions() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let statsStore = UserStatsStore(container: container)
        let context = ModelContext(container)
        context.insert(
            PotholeActionRecord(
                actionType: .manualReport,
                latitude: 44.6488,
                longitude: -63.5752,
                accuracyM: 6,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_000.0),
                createdAt: Date(timeIntervalSince1970: 1_713_000_000.0),
                uploadState: .pendingUpload
            )
        )
        context.insert(
            PotholeActionRecord(
                actionType: .manualReport,
                latitude: 44.6490,
                longitude: -63.5750,
                accuracyM: 5,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010.0),
                createdAt: Date(timeIntervalSince1970: 1_713_000_010.0),
                uploadState: .failedPermanent
            )
        )
        context.insert(
            PotholeActionRecord(
                potholeReportID: UUID(),
                actionType: .confirmPresent,
                latitude: 44.6492,
                longitude: -63.5748,
                accuracyM: 5,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_020.0),
                createdAt: Date(timeIntervalSince1970: 1_713_000_020.0),
                uploadState: .pendingUpload
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6494,
                longitude: -63.5746,
                roughnessRMS: 1.1,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 6,
                isPothole: true,
                potholeMagnitude: 2.5,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_030.0)
            )
        )
        try context.save()

        XCTAssertEqual(try store.reconcileManualReportStats(), 3)
        XCTAssertEqual(try statsStore.summary().potholesReported, 3)
        XCTAssertEqual(try store.reconcileManualReportStats(), 0)
        XCTAssertEqual(try statsStore.summary().potholesReported, 3)
    }

    func testQueueFollowUpActionCreatesPendingUploadRecord() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let potholeID = UUID()
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 40,
            headingDegrees: 180
        )

        let record = try store.queueFollowUpAction(
            potholeReportID: potholeID,
            actionType: .confirmFixed,
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )

        XCTAssertEqual(record.potholeReportID, potholeID)
        XCTAssertEqual(record.actionType, .confirmFixed)
        XCTAssertEqual(record.uploadState, .pendingUpload)
        XCTAssertNil(record.undoExpiresAt)
    }

    func testQueueFollowUpActionDedupesPendingUploadForSamePotholeAndType() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let potholeID = UUID()
        let firstSample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 40,
            headingDegrees: 180
        )
        let secondSample = LocationSample(
            timestamp: 1_713_000_010.0,
            latitude: 44.6489,
            longitude: -63.5751,
            horizontalAccuracyMeters: 5,
            speedKmh: 38,
            headingDegrees: 182
        )

        let first = try store.queueFollowUpAction(
            potholeReportID: potholeID,
            actionType: .confirmPresent,
            sample: firstSample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )
        let second = try store.queueFollowUpAction(
            potholeReportID: potholeID,
            actionType: .confirmPresent,
            sample: secondSample,
            now: Date(timeIntervalSince1970: 1_713_000_010.0)
        )

        XCTAssertEqual(first.id, second.id)

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.latitude, secondSample.latitude)
        XCTAssertEqual(records.first?.actionType, .confirmPresent)
    }

    func testDiscardIgnoresAlreadyQueuedUpload() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let potholeID = UUID()
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 40,
            headingDegrees: 180
        )

        let record = try store.queueFollowUpAction(
            potholeReportID: potholeID,
            actionType: .confirmPresent,
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )

        try store.discard(id: record.id)

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, record.id)
        XCTAssertEqual(try store.pendingCount(), 1)
    }

    func testDiscardIgnoresExpiredPendingUndoAction() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 40,
            headingDegrees: 180
        )

        let record = try store.queueManualReport(
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )

        try store.discard(
            id: record.id,
            now: Date(timeIntervalSince1970: 1_713_000_006.0)
        )

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, record.id)
        XCTAssertEqual(records.first?.uploadState, .pendingUndo)
    }

    func testStatusSummaryCountsPendingAndFailedPermanentActions() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let context = ModelContext(container)

        let pending = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 6,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            uploadState: .pendingUpload,
            uploadAttemptCount: 1,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_020.0),
            nextAttemptAt: Date(timeIntervalSince1970: 1_713_000_060.0),
            lastHTTPStatusCode: 503
        )
        let failed = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6490,
            longitude: -63.5750,
            accuracyM: 5,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_010.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_010.0),
            uploadState: .failedPermanent,
            uploadAttemptCount: 2,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_030.0),
            lastHTTPStatusCode: 404
        )
        let uploaded = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6491,
            longitude: -63.5749,
            accuracyM: 4,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_005.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_005.0),
            uploadState: .pendingUpload,
            uploadAttemptCount: 1,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_025.0),
            uploadedAt: Date(timeIntervalSince1970: 1_713_000_025.0)
        )
        context.insert(pending)
        context.insert(failed)
        context.insert(uploaded)
        try context.save()

        let summary = try store.statusSummary(now: Date(timeIntervalSince1970: 1_713_000_040.0))

        // Uploaded records are kept around for stat reconciliation but must not
        // count as pending work or failed work.
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertEqual(summary.failedPermanentCount, 1)
        XCTAssertEqual(summary.nextRetryAt, Date(timeIntervalSince1970: 1_713_000_060.0))
        XCTAssertEqual(summary.lastSuccessfulUploadAt, Date(timeIntervalSince1970: 1_713_000_025.0))
    }

    func testApplyUploadSuccessSoftDeletesRecordSoReconcilePreservesCount() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let statsStore = UserStatsStore(container: container)
        let sample = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 50,
            headingDegrees: 180
        )

        let record = try store.queueManualReport(
            sample: sample,
            now: Date(timeIntervalSince1970: 1_713_000_000.0)
        )
        _ = try store.promoteExpiredPendingUndoActions(
            now: Date(timeIntervalSince1970: 1_713_000_006.0)
        )
        try store.applyUploadSuccess(
            id: record.id,
            now: Date(timeIntervalSince1970: 1_713_000_010.0)
        )

        // Row stays in the table after a clean upload.
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.uploadedAt, Date(timeIntervalSince1970: 1_713_000_010.0))

        // Pending work counters exclude uploaded rows.
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertTrue(try store.pendingManualReportCoordinates().isEmpty)

        // Stat survives — and stays correct after a stat reset (the original bug).
        XCTAssertEqual(try statsStore.summary().potholesReported, 1)

        let stats = try context.fetch(FetchDescriptor<UserStats>()).first
        stats?.potholesReported = 0
        try context.save()

        let recovered = try store.reconcileManualReportStats()
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try statsStore.summary().potholesReported, 1)
    }

    func testRetryFailedActionsMovesRecordsBackToPendingUpload() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let context = ModelContext(container)

        let failed = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 6,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            uploadState: .failedPermanent,
            uploadAttemptCount: 2,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_030.0),
            nextAttemptAt: Date(timeIntervalSince1970: 1_713_000_120.0),
            lastHTTPStatusCode: 404,
            lastRequestID: "req_404"
        )
        context.insert(failed)
        try context.save()

        try store.retryFailedActions()

        let refreshed = try context.fetch(FetchDescriptor<PotholeActionRecord>()).first
        XCTAssertEqual(refreshed?.uploadState, .pendingUpload)
        XCTAssertEqual(refreshed?.uploadAttemptCount, 0)
        XCTAssertNil(refreshed?.lastAttemptAt)
        XCTAssertNil(refreshed?.nextAttemptAt)
        XCTAssertNil(refreshed?.lastHTTPStatusCode)
        XCTAssertNil(refreshed?.lastRequestID)
    }

    func testRecoverRecoverableFailuresOnlyResetsRetryableHTTPStatuses() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let context = ModelContext(container)

        let retryable = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 6,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            uploadState: .failedPermanent,
            uploadAttemptCount: 2,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_030.0),
            lastHTTPStatusCode: 404,
            lastRequestID: "req_404"
        )
        let permanent = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6489,
            longitude: -63.5751,
            accuracyM: 6,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_010.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_010.0),
            uploadState: .failedPermanent,
            uploadAttemptCount: 1,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_040.0),
            lastHTTPStatusCode: 400,
            lastRequestID: "req_400"
        )
        context.insert(retryable)
        context.insert(permanent)
        try context.save()

        let recovered = try store.recoverRecoverableFailures()
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        let refreshedRetryable = records.first(where: { $0.id == retryable.id })
        let refreshedPermanent = records.first(where: { $0.id == permanent.id })

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(refreshedRetryable?.uploadState, .pendingUpload)
        XCTAssertEqual(refreshedRetryable?.uploadAttemptCount, 0)
        XCTAssertNil(refreshedRetryable?.lastAttemptAt)
        XCTAssertNil(refreshedRetryable?.lastHTTPStatusCode)
        XCTAssertNil(refreshedRetryable?.lastRequestID)
        XCTAssertEqual(refreshedPermanent?.uploadState, .failedPermanent)
        XCTAssertEqual(refreshedPermanent?.lastHTTPStatusCode, 400)
    }

    func testPendingManualReportCoordinatesIncludesOnlyNonFailedManualReports() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = PotholeActionStore(container: container)
        let context = ModelContext(container)

        let pendingUndo = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 6,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_000.0),
            undoExpiresAt: Date(timeIntervalSince1970: 1_713_000_005.0),
            uploadState: .pendingUndo
        )
        let pendingUpload = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6490,
            longitude: -63.5750,
            accuracyM: 5,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_010.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_010.0),
            uploadState: .pendingUpload
        )
        let failed = PotholeActionRecord(
            actionType: .manualReport,
            latitude: 44.6492,
            longitude: -63.5748,
            accuracyM: 5,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_020.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_020.0),
            uploadState: .failedPermanent
        )
        let followUp = PotholeActionRecord(
            potholeReportID: UUID(),
            actionType: .confirmPresent,
            latitude: 44.6494,
            longitude: -63.5746,
            accuracyM: 5,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_030.0),
            createdAt: Date(timeIntervalSince1970: 1_713_000_030.0),
            uploadState: .pendingUpload
        )
        context.insert(pendingUndo)
        context.insert(pendingUpload)
        context.insert(failed)
        context.insert(followUp)
        try context.save()

        let coordinates = try store.pendingManualReportCoordinates()

        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(coordinates.first?.latitude, pendingUndo.latitude)
        XCTAssertEqual(coordinates.first?.longitude, pendingUndo.longitude)
        XCTAssertEqual(coordinates.last?.latitude, pendingUpload.latitude)
        XCTAssertEqual(coordinates.last?.longitude, pendingUpload.longitude)
    }
}
