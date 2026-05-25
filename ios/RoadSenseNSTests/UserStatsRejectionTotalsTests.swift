import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class UserStatsRejectionTotalsTests: XCTestCase {
    func testSummaryReturnsEmptyTotalsForFreshStore() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let store = UserStatsStore(container: container)

        let summary = try store.summary()
        XCTAssertTrue(summary.lifetimeRejectionTotals.isEmpty)
        XCTAssertTrue(summary.lastTripRejectionTotals.isEmpty)
        XCTAssertNil(summary.lastTripStartedAt)
        XCTAssertNil(summary.lastTripEndedAt)
    }

    func testSummaryAggregatesLastGroupedTripAcrossSessions() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)

        let sessionAStart = Date(timeIntervalSince1970: 1_713_000_000)
        let sessionAEnd = Date(timeIntervalSince1970: 1_713_000_600)
        let sessionBStart = Date(timeIntervalSince1970: 1_713_000_640) // 40s gap
        let sessionBEnd = Date(timeIntervalSince1970: 1_713_001_200)
        let sessionLater = Date(timeIntervalSince1970: 1_713_010_000)
        let sessionLaterEnd = Date(timeIntervalSince1970: 1_713_010_600)

        var totalsA = ReadingDiagnosticTotals.empty
        totalsA.increment(.builderSampleCount, by: 4)
        totalsA.increment(.qualitySpeed, by: 1)

        var totalsB = ReadingDiagnosticTotals.empty
        totalsB.increment(.builderSampleCount, by: 2)
        totalsB.increment(.builderHeadingVariance, by: 5)

        var totalsLater = ReadingDiagnosticTotals.empty
        totalsLater.increment(.qualityThermal, by: 1)

        context.insert(
            DriveSessionRecord(
                id: UUID(),
                startedAt: sessionAStart,
                endedAt: sessionAEnd,
                startLatitude: 44.0,
                startLongitude: -63.0,
                isSealed: true,
                rejectionTotalsJSON: totalsA.encodedJSON()
            )
        )
        context.insert(
            DriveSessionRecord(
                id: UUID(),
                startedAt: sessionBStart,
                endedAt: sessionBEnd,
                startLatitude: 44.0,
                startLongitude: -63.0,
                isSealed: true,
                rejectionTotalsJSON: totalsB.encodedJSON()
            )
        )
        context.insert(
            DriveSessionRecord(
                id: UUID(),
                startedAt: sessionLater,
                endedAt: sessionLaterEnd,
                startLatitude: 44.0,
                startLongitude: -63.0,
                isSealed: true,
                rejectionTotalsJSON: totalsLater.encodedJSON()
            )
        )

        var lifetime = ReadingDiagnosticTotals.empty
        lifetime.add(totalsA)
        lifetime.add(totalsB)
        lifetime.add(totalsLater)
        context.insert(UserStats(rejectionTotalsJSON: lifetime.encodedJSON()))
        try context.save()

        let store = UserStatsStore(container: container)
        let summary = try store.summary()

        XCTAssertEqual(summary.totalTripsRecorded, 2,
                       "a 40s gap stays inside one trip; the later session is its own trip")
        XCTAssertEqual(summary.lastTripRejectionTotals.count(for: .qualityThermal), 1)
        XCTAssertEqual(summary.lastTripRejectionTotals.count(for: .builderSampleCount), 0)
        XCTAssertEqual(summary.lastTripStartedAt, sessionLater)
        XCTAssertEqual(summary.lastTripEndedAt, sessionLaterEnd)

        XCTAssertEqual(summary.lifetimeRejectionTotals.count(for: .builderSampleCount), 6)
        XCTAssertEqual(summary.lifetimeRejectionTotals.count(for: .builderHeadingVariance), 5)
        XCTAssertEqual(summary.lifetimeRejectionTotals.count(for: .qualitySpeed), 1)
        XCTAssertEqual(summary.lifetimeRejectionTotals.count(for: .qualityThermal), 1)
    }

    func testSummaryGroupsAdjacentSessionsIntoOneTrip() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)

        let firstStart = Date(timeIntervalSince1970: 1_713_000_000)
        let firstEnd = Date(timeIntervalSince1970: 1_713_000_300)
        let secondStart = Date(timeIntervalSince1970: 1_713_000_320) // 20s gap → same trip
        let secondEnd = Date(timeIntervalSince1970: 1_713_000_700)

        var totalsFirst = ReadingDiagnosticTotals.empty
        totalsFirst.increment(.builderSampleCount, by: 3)

        var totalsSecond = ReadingDiagnosticTotals.empty
        totalsSecond.increment(.qualitySpeed, by: 7)

        context.insert(
            DriveSessionRecord(
                id: UUID(),
                startedAt: firstStart,
                endedAt: firstEnd,
                startLatitude: 44.0,
                startLongitude: -63.0,
                isSealed: true,
                rejectionTotalsJSON: totalsFirst.encodedJSON()
            )
        )
        context.insert(
            DriveSessionRecord(
                id: UUID(),
                startedAt: secondStart,
                endedAt: secondEnd,
                startLatitude: 44.0,
                startLongitude: -63.0,
                isSealed: true,
                rejectionTotalsJSON: totalsSecond.encodedJSON()
            )
        )
        try context.save()

        let store = UserStatsStore(container: container)
        let summary = try store.summary()

        XCTAssertEqual(summary.totalTripsRecorded, 1)
        XCTAssertEqual(summary.lastTripRejectionTotals.count(for: .builderSampleCount), 3)
        XCTAssertEqual(summary.lastTripRejectionTotals.count(for: .qualitySpeed), 7)
        XCTAssertEqual(summary.lastTripStartedAt, firstStart)
        XCTAssertEqual(summary.lastTripEndedAt, secondEnd)
    }
}
