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
