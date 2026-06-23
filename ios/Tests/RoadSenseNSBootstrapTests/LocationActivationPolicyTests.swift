import XCTest
@testable import RoadSenseNSBootstrap

final class LocationActivationPolicyTests: XCTestCase {
    // The regression that caused all-day battery drain: while the app is backgrounded
    // and the user is merely walking around (passive standby, no drive), the GPS chip
    // must NOT be held at full power. Only low-power significant-change monitoring runs.
    func testBackgroundedPassiveStandbyUsesLowPowerOnly() {
        let decision = LocationActivationPolicy.decide(
            isPassiveMonitoring: true,
            isCollecting: false,
            isForeground: false
        )

        XCTAssertFalse(decision.usesContinuousUpdates)
        XCTAssertTrue(decision.usesSignificantLocationChanges)
    }

    // A real drive must record with continuous high-accuracy GPS even when the app is
    // backgrounded (phone in pocket / screen locked while driving).
    func testBackgroundedActiveDriveUsesContinuousUpdates() {
        let decision = LocationActivationPolicy.decide(
            isPassiveMonitoring: true,
            isCollecting: true,
            isForeground: false
        )

        XCTAssertTrue(decision.usesContinuousUpdates)
        XCTAssertTrue(decision.usesSignificantLocationChanges)
    }

    // Foreground standby (user looking at the map, maybe filing a manual pothole
    // report) needs a fresh fix, so continuous updates are acceptable there.
    func testForegroundPassiveStandbyUsesContinuousUpdates() {
        let decision = LocationActivationPolicy.decide(
            isPassiveMonitoring: true,
            isCollecting: false,
            isForeground: true
        )

        XCTAssertTrue(decision.usesContinuousUpdates)
        XCTAssertTrue(decision.usesSignificantLocationChanges)
    }

    func testForegroundActiveDriveUsesContinuousUpdates() {
        let decision = LocationActivationPolicy.decide(
            isPassiveMonitoring: true,
            isCollecting: true,
            isForeground: true
        )

        XCTAssertTrue(decision.usesContinuousUpdates)
        XCTAssertTrue(decision.usesSignificantLocationChanges)
    }

    // When the user has paused collection entirely, nothing should run — not even
    // significant-change monitoring — regardless of foreground state.
    func testMonitoringDisabledRunsNothing() {
        for isForeground in [true, false] {
            let decision = LocationActivationPolicy.decide(
                isPassiveMonitoring: false,
                isCollecting: false,
                isForeground: isForeground
            )

            XCTAssertFalse(decision.usesContinuousUpdates, "foreground=\(isForeground)")
            XCTAssertFalse(decision.usesSignificantLocationChanges, "foreground=\(isForeground)")
        }
    }
}
