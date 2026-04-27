import Foundation
import XCTest
@testable import RoadSense_NS

final class DriveListGrouperTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Halifax")!
        return calendar
    }()

    func testGroupingPlacesDrivesIntoTodayYesterdayEarlierThisWeekAndEarlier() {
        // 2026-04-29 (Wednesday) 10:00 local time, NS
        let now = makeDate(year: 2026, month: 4, day: 29, hour: 10)

        let summaries = [
            makeSummary(id: "today-late", at: makeDate(year: 2026, month: 4, day: 29, hour: 9)),
            makeSummary(id: "today-early", at: makeDate(year: 2026, month: 4, day: 29, hour: 0, minute: 30)),
            makeSummary(id: "yesterday", at: makeDate(year: 2026, month: 4, day: 28, hour: 18)),
            makeSummary(id: "earlier-week", at: makeDate(year: 2026, month: 4, day: 27, hour: 8)),
            makeSummary(id: "older", at: makeDate(year: 2026, month: 4, day: 19, hour: 12)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.bucket), [.today, .yesterday, .earlierThisWeek, .earlier])
        XCTAssertEqual(sections[0].drives.map(\.id.uuidString), ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"])
        XCTAssertEqual(sections[1].drives.map(\.id.uuidString), ["00000000-0000-0000-0000-000000000003"])
        XCTAssertEqual(sections[2].drives.map(\.id.uuidString), ["00000000-0000-0000-0000-000000000004"])
        XCTAssertEqual(sections[3].drives.map(\.id.uuidString), ["00000000-0000-0000-0000-000000000005"])
    }

    func testGroupingProducesNoSectionsForEmptyInput() {
        let now = makeDate(year: 2026, month: 4, day: 29, hour: 10)
        XCTAssertEqual(DriveListGrouper.group([], now: now, calendar: calendar), [])
    }

    func testGroupingDoesNotEmitEmptySections() {
        let now = makeDate(year: 2026, month: 4, day: 29, hour: 10)
        let summaries = [
            makeSummary(id: "today", at: now.addingTimeInterval(-60 * 60)),
            makeSummary(id: "today-2", at: now.addingTimeInterval(-90 * 60)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.bucket, .today)
    }

    func testGroupingHandlesSpringDSTTransitionInHalifax() {
        // Halifax 2026 spring-forward: 2026-03-08 02:00 ADT -> 03:00 ADT
        // A drive started 1am Mar 8 (still AST) is "today" if now is mid-day Mar 8.
        let now = makeDate(year: 2026, month: 3, day: 8, hour: 14)
        let summaries = [
            makeSummary(id: "early", at: makeDate(year: 2026, month: 3, day: 8, hour: 1)),
            makeSummary(id: "yesterday", at: makeDate(year: 2026, month: 3, day: 7, hour: 22)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.bucket), [.today, .yesterday])
    }

    func testGroupingHandlesFallDSTTransitionInHalifax() {
        // Halifax 2026 fall-back: 2026-11-01 02:00 ADT -> 01:00 AST
        // A drive started 1:30 AM (the second 1:30 AM) and now at noon: still "today".
        let now = makeDate(year: 2026, month: 11, day: 1, hour: 12)
        let summaries = [
            makeSummary(id: "early-today", at: makeDate(year: 2026, month: 11, day: 1, hour: 1, minute: 30)),
            makeSummary(id: "yesterday", at: makeDate(year: 2026, month: 10, day: 31, hour: 23)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.bucket), [.today, .yesterday])
    }

    func testGroupingPlacesDriveAtExactMidnightIntoToday() {
        let now = makeDate(year: 2026, month: 4, day: 29, hour: 10)
        let summaries = [
            makeSummary(id: "midnight", at: makeDate(year: 2026, month: 4, day: 29, hour: 0, minute: 0)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.first?.bucket, .today)
    }

    func testGroupingPlacesDriveJustBeforeMidnightIntoYesterday() {
        let now = makeDate(year: 2026, month: 4, day: 29, hour: 10)
        let summaries = [
            makeSummary(id: "almost-midnight", at: makeDate(year: 2026, month: 4, day: 28, hour: 23, minute: 59)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.first?.bucket, .yesterday)
    }

    func testGroupingHandlesYearBoundaryWithoutMixingBuckets() {
        // Now is 2026-01-02 (Friday); week-of-year started 2025-12-29 (Monday).
        // A 2025-12-30 drive should land in "earlier this week" because they share weekOfYear.
        let now = makeDate(year: 2026, month: 1, day: 2, hour: 10)
        let summaries = [
            makeSummary(id: "today", at: makeDate(year: 2026, month: 1, day: 2, hour: 8)),
            makeSummary(id: "yesterday", at: makeDate(year: 2026, month: 1, day: 1, hour: 18)),
            makeSummary(id: "monday-prior-year", at: makeDate(year: 2025, month: 12, day: 30, hour: 10)),
            makeSummary(id: "long-ago", at: makeDate(year: 2025, month: 12, day: 22, hour: 10)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.bucket), [.today, .yesterday, .earlierThisWeek, .earlier])
    }

    func testGroupingPlacesFutureDrivesIntoToday() {
        // Defensive: clock skew or time-zone bugs could produce a "future" timestamp.
        // The grouper should not crash, and should not silently drop the drive.
        let now = makeDate(year: 2026, month: 4, day: 29, hour: 10)
        let summaries = [
            makeSummary(id: "future", at: now.addingTimeInterval(60 * 60)),
        ]

        let sections = DriveListGrouper.group(summaries, now: now, calendar: calendar)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.bucket, .today)
    }

    private var idCounter = 0
    private func makeSummary(id: String, at startedAt: Date) -> DriveSummary {
        idCounter += 1
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idCounter))!
        return DriveSummary(
            id: uuid,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15 * 60),
            isSealed: true,
            acceptedReadingCount: 12,
            privacyFilteredReadingCount: 0,
            potholeCount: 0,
            distanceKm: 4.2,
            bbox: DriveBoundingBox(
                minLatitude: 44.6,
                minLongitude: -63.6,
                maxLatitude: 44.7,
                maxLongitude: -63.5
            )
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/Halifax")
        return calendar.date(from: components)!
    }
}
