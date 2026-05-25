import XCTest
@testable import RoadSense_NS

final class StatsViewSkipGroupsTests: XCTestCase {
    func testSlowGroupCoversQualitySpeed() {
        var totals = ReadingDiagnosticTotals.empty
        totals.increment(.qualitySpeed, by: 34)
        let groups = StatsView.skipGroups(for: totals)
        XCTAssertEqual(groups.first { $0.id == "slow" }?.count, 34)
    }

    func testGpsGroupSumsBuilderAndQualityReasons() {
        var totals = ReadingDiagnosticTotals.empty
        totals.increment(.builderGpsAccuracy, by: 7)
        totals.increment(.qualityGpsAccuracy, by: 4)
        let groups = StatsView.skipGroups(for: totals)
        XCTAssertEqual(groups.first { $0.id == "gps" }?.count, 11)
    }

    func testSensorGroupSumsBuilderAndQualitySampleCount() {
        var totals = ReadingDiagnosticTotals.empty
        totals.increment(.builderSampleCount, by: 3)
        totals.increment(.qualitySampleCount, by: 1)
        let groups = StatsView.skipGroups(for: totals)
        XCTAssertEqual(groups.first { $0.id == "sensor" }?.count, 4)
    }

    func testIncompleteGroupReflectsBuilderPartialAtSeal() {
        var totals = ReadingDiagnosticTotals.empty
        totals.increment(.builderPartialAtSeal, by: 2)
        let groups = StatsView.skipGroups(for: totals)
        XCTAssertEqual(groups.first { $0.id == "incomplete" }?.count, 2)
    }

    func testEmptyTotalsProduceAllZeroGroups() {
        let groups = StatsView.skipGroups(for: .empty)
        XCTAssertTrue(groups.allSatisfy { $0.count == 0 })
        XCTAssertFalse(groups.isEmpty)
    }
}
