import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class ReadingRejectionRecorderTests: XCTestCase {
    func testRecordingAndFlushingPersistsLifetimeAndPerSessionTotals() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)
        let sessionID = UUID()
        context.insert(
            DriveSessionRecord(
                id: sessionID,
                startedAt: Date(timeIntervalSince1970: 1_713_000_000),
                endedAt: Date(timeIntervalSince1970: 1_713_001_000),
                startLatitude: 44.64,
                startLongitude: -63.57,
                isSealed: true
            )
        )
        try context.save()

        let recorder = ReadingRejectionRecorder(container: container)
        recorder.recordReadingWindowReset(.builderSampleCount, sessionID: sessionID)
        recorder.recordReadingWindowReset(.builderSampleCount, sessionID: sessionID)
        recorder.recordQualityRejection(.speed, sessionID: sessionID)
        recorder.recordQualityRejection(.gpsAccuracy, sessionID: nil)
        recorder.recordPersistFailure(sessionID: sessionID)
        recorder.recordPartialAtSeal(sessionID: sessionID)

        XCTAssertTrue(recorder.flush())

        let refreshed = ModelContext(container)
        let stats = try refreshed.fetch(FetchDescriptor<UserStats>()).first
        let session = try refreshed.fetch(
            FetchDescriptor<DriveSessionRecord>(predicate: #Predicate { $0.id == sessionID })
        ).first

        let lifetime = ReadingDiagnosticTotals.decode(fromJSON: stats?.rejectionTotalsJSON)
        XCTAssertEqual(lifetime.count(for: .builderSampleCount), 2)
        XCTAssertEqual(lifetime.count(for: .qualitySpeed), 1)
        XCTAssertEqual(lifetime.count(for: .qualityGpsAccuracy), 1)
        XCTAssertEqual(lifetime.count(for: .persistFailure), 1)
        XCTAssertEqual(lifetime.count(for: .builderPartialAtSeal), 1)
        XCTAssertEqual(lifetime.total(for: .readingWindow), 6)

        let perSession = ReadingDiagnosticTotals.decode(fromJSON: session?.rejectionTotalsJSON)
        XCTAssertEqual(perSession.count(for: .builderSampleCount), 2)
        XCTAssertEqual(perSession.count(for: .qualitySpeed), 1)
        XCTAssertEqual(perSession.count(for: .qualityGpsAccuracy), 0,
                       "session-less event must not leak into a session blob")
        XCTAssertEqual(perSession.count(for: .builderPartialAtSeal), 1)
    }

    func testFlushIsIdempotentWithNothingPending() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let recorder = ReadingRejectionRecorder(container: container)
        XCTAssertFalse(recorder.flush())
    }

    func testFlushAccumulatesAcrossMultipleCalls() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let recorder = ReadingRejectionRecorder(container: container)

        recorder.recordReadingWindowReset(.builderHeadingVariance, sessionID: nil)
        XCTAssertTrue(recorder.flush())

        recorder.recordReadingWindowReset(.builderHeadingVariance, sessionID: nil)
        recorder.recordReadingWindowReset(.builderHeadingVariance, sessionID: nil)
        XCTAssertTrue(recorder.flush())

        let context = ModelContext(container)
        let stats = try context.fetch(FetchDescriptor<UserStats>()).first
        let totals = ReadingDiagnosticTotals.decode(fromJSON: stats?.rejectionTotalsJSON)
        XCTAssertEqual(totals.count(for: .builderHeadingVariance), 3)
    }

    func testPreCollectionSampleCounterDoesNotPersist() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let recorder = ReadingRejectionRecorder(container: container)

        recorder.recordPreCollectionLocationSample()
        recorder.recordPreCollectionLocationSample()
        recorder.recordPreCollectionLocationSample()

        XCTAssertEqual(recorder.preCollectionLocationSampleCount, 3)
        XCTAssertFalse(recorder.flush())

        let context = ModelContext(container)
        let stats = try context.fetch(FetchDescriptor<UserStats>()).first
        XCTAssertNil(stats?.rejectionTotalsJSON,
                     "pre-collection events must not flush to the lifetime blob")
    }

    func testReadingWindowResetIgnoresWrongUnitReason() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let recorder = ReadingRejectionRecorder(container: container)
        recorder.recordReadingWindowReset(.privacyZone, sessionID: nil)
        XCTAssertFalse(recorder.flush())
    }
}
