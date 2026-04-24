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
}
