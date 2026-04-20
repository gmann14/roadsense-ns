import XCTest

final class AppFlowUITests: XCTestCase {
    func testPrivacyGateCanCreateZoneAndUnlockReadyState() {
        let app = XCUIApplication()
        app.launchEnvironment["ROAD_SENSE_UI_TESTS"] = "1"
        app.launchEnvironment["ROAD_SENSE_TEST_SCENARIO"] = "default"
        app.launch()

        XCTAssertTrue(app.staticTexts["Set up privacy protection before collection starts."].waitForExistence(timeout: 5))

        app.buttons["Manage privacy zones"].tap()

        let saveButton = app.buttons["privacy-zones.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        XCTAssertTrue(app.staticTexts["RoadSense NS is ready to collect."].waitForExistence(timeout: 5))
    }

    func testReadyShellCanOpenSettingsAndPrivacyEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["ROAD_SENSE_UI_TESTS"] = "1"
        app.launchEnvironment["ROAD_SENSE_TEST_SCENARIO"] = "ready-shell"
        app.launch()

        XCTAssertTrue(app.staticTexts["map.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["map.settings-button"].waitForExistence(timeout: 8))

        app.buttons["map.settings-button"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.manage-privacy-zones"].exists)

        app.buttons["settings.manage-privacy-zones"].tap()

        XCTAssertTrue(app.otherElements["privacy-zones.map"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["privacy-zone.Home"].waitForExistence(timeout: 5))
    }

    func testReadyShellCanOpenStatsAndShowSeededCounts() {
        let app = XCUIApplication()
        app.launchEnvironment["ROAD_SENSE_UI_TESTS"] = "1"
        app.launchEnvironment["ROAD_SENSE_TEST_SCENARIO"] = "ready-shell"
        app.launch()

        XCTAssertTrue(app.buttons["map.stats-button"].waitForExistence(timeout: 8))
        app.buttons["map.stats-button"].tap()

        XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["stats.accepted-readings"].label.contains("2"))
        XCTAssertTrue(app.staticTexts["stats.pending-uploads"].label.contains("2"))
        XCTAssertTrue(app.staticTexts["stats.privacy-filtered"].label.contains("1"))
        XCTAssertTrue(app.staticTexts["stats.potholes-flagged"].label.contains("1"))
    }

    func testDeletingLocalDataClearsSeededStats() {
        let app = XCUIApplication()
        app.launchEnvironment["ROAD_SENSE_UI_TESTS"] = "1"
        app.launchEnvironment["ROAD_SENSE_TEST_SCENARIO"] = "ready-shell"
        app.launch()

        XCTAssertTrue(app.buttons["map.settings-button"].waitForExistence(timeout: 8))
        app.buttons["map.settings-button"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings.delete-local-data"].tap()
        app.buttons["settings.close"].tap()

        XCTAssertTrue(app.buttons["map.stats-button"].waitForExistence(timeout: 5))
        app.buttons["map.stats-button"].tap()

        XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["stats.accepted-readings"].label.contains("0"))
        XCTAssertTrue(app.staticTexts["stats.pending-uploads"].label.contains("0"))
        XCTAssertTrue(app.staticTexts["stats.privacy-filtered"].label.contains("0"))
        XCTAssertTrue(app.staticTexts["stats.segments-contributed"].label.contains("0"))
    }
}
