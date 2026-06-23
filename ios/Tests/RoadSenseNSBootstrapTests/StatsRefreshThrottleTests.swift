import XCTest
@testable import RoadSenseNSBootstrap

final class StatsRefreshThrottleTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_713_000_000)

    func testFirstCallAlwaysRefreshes() {
        var throttle = StatsRefreshThrottle(minimumInterval: 2)
        XCTAssertTrue(throttle.shouldRefresh(now: epoch))
    }

    func testSuppressesRefreshesWithinInterval() {
        var throttle = StatsRefreshThrottle(minimumInterval: 2)

        XCTAssertTrue(throttle.shouldRefresh(now: epoch))
        XCTAssertFalse(throttle.shouldRefresh(now: epoch.addingTimeInterval(0.5)))
        XCTAssertFalse(throttle.shouldRefresh(now: epoch.addingTimeInterval(1.9)))
    }

    func testAllowsRefreshAfterInterval() {
        var throttle = StatsRefreshThrottle(minimumInterval: 2)

        XCTAssertTrue(throttle.shouldRefresh(now: epoch))
        XCTAssertFalse(throttle.shouldRefresh(now: epoch.addingTimeInterval(1)))
        XCTAssertTrue(throttle.shouldRefresh(now: epoch.addingTimeInterval(2)))
        // The window resets from the last *allowed* refresh, not the suppressed call.
        XCTAssertFalse(throttle.shouldRefresh(now: epoch.addingTimeInterval(3)))
        XCTAssertTrue(throttle.shouldRefresh(now: epoch.addingTimeInterval(4)))
    }

    func testMarkRefreshedResetsWindow() {
        var throttle = StatsRefreshThrottle(minimumInterval: 2)

        XCTAssertTrue(throttle.shouldRefresh(now: epoch))
        // An external (non-throttled) full refresh happens just before the window expires.
        throttle.markRefreshed(now: epoch.addingTimeInterval(1.5))
        // The throttle now measures from that external refresh.
        XCTAssertFalse(throttle.shouldRefresh(now: epoch.addingTimeInterval(3)))
        XCTAssertTrue(throttle.shouldRefresh(now: epoch.addingTimeInterval(3.5)))
    }
}
