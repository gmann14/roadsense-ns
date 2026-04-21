import XCTest
@testable import RoadSense_NS

final class ManualPotholeLocatorTests: XCTestCase {
    func testLocateChoosesBufferedSampleClosestToReactionAdjustedTime() {
        let locator = ManualPotholeLocator()
        let tapTimestamp = 1_713_000_000.0
        let older = LocationSample(
            timestamp: tapTimestamp - 1.5,
            latitude: 44.6480,
            longitude: -63.5760,
            horizontalAccuracyMeters: 8,
            speedKmh: 48,
            headingDegrees: 180
        )
        let closest = LocationSample(
            timestamp: tapTimestamp - 0.78,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 48,
            headingDegrees: 180
        )

        let chosen = locator.locate(
            tapTimestamp: Date(timeIntervalSince1970: tapTimestamp),
            recentSamples: [older, closest],
            latestSample: older
        )

        XCTAssertEqual(chosen?.timestamp, closest.timestamp)
        XCTAssertEqual(chosen?.latitude, closest.latitude)
    }

    func testLocateFallsBackToLatestSampleWhenBufferIsEmpty() {
        let locator = ManualPotholeLocator()
        let latest = LocationSample(
            timestamp: 1_713_000_000.0,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 48,
            headingDegrees: 180
        )

        let chosen = locator.locate(
            tapTimestamp: Date(timeIntervalSince1970: 1_713_000_001.0),
            recentSamples: [],
            latestSample: latest
        )

        XCTAssertEqual(chosen?.timestamp, latest.timestamp)
    }
}
