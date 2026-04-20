import XCTest

final class AppFlowUITests: XCTestCase {
    func testPrivacyGateCanCreateZoneAndUnlockReadyState() {
        let app = makeApp(scenario: "default")
        app.launch()

        XCTAssertTrue(app.staticTexts["Set up privacy protection before collection starts."].waitForExistence(timeout: 5))

        app.buttons["Manage privacy zones"].tap()

        let saveButton = app.buttons["privacy-zones.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        XCTAssertTrue(app.buttons["map.settings-button"].waitForExistence(timeout: 5))
    }

    func testReadyShellCanOpenSettingsAndPrivacyEditor() {
        let app = makeApp(scenario: "ready-shell")
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
        let app = makeApp(scenario: "ready-shell")
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
        let app = makeApp(scenario: "ready-shell")
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

    func testPrivacyGateRemainsUsableAtAccessibilitySize() {
        let app = makeApp(scenario: "default", dynamicTypeSize: "accessibility5")
        app.launch()

        XCTAssertTrue(app.buttons["onboarding.manage-privacy-zones"].waitForExistence(timeout: 5))
        app.buttons["onboarding.manage-privacy-zones"].tap()

        XCTAssertTrue(app.buttons["privacy-zones.save"].waitForExistence(timeout: 5))
        app.buttons["privacy-zones.save"].tap()

        XCTAssertTrue(app.buttons["map.settings-button"].waitForExistence(timeout: 5))
    }

    func testReadyShellModalsRemainUsableAtAccessibilitySize() {
        let app = makeApp(scenario: "ready-shell", dynamicTypeSize: "accessibility5")
        app.launch()

        XCTAssertTrue(app.buttons["map.stats-button"].waitForExistence(timeout: 8))
        app.buttons["map.stats-button"].tap()
        XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stats.close"].waitForExistence(timeout: 5))
        app.buttons["stats.close"].tap()

        XCTAssertTrue(app.buttons["map.settings-button"].waitForExistence(timeout: 5))
        app.buttons["map.settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.manage-privacy-zones"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 5))
    }

    private func makeApp(scenario: String, dynamicTypeSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ROAD_SENSE_UI_TESTS"] = "1"
        app.launchEnvironment["ROAD_SENSE_TEST_SCENARIO"] = scenario

        if let dynamicTypeSize {
            app.launchEnvironment["ROAD_SENSE_DYNAMIC_TYPE_SIZE"] = dynamicTypeSize
        }

        return app
    }
}
