import Foundation
import XCTest
@testable import RoadSense_NS

@MainActor
final class UploadHealthAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    func testReturnsNilWhenNothingPendingAndNoFailures() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: now.addingTimeInterval(-30 * 60),
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 0,
            pendingPotholeMarkCount: 0,
            pendingPhotoCount: 0
        )

        XCTAssertNil(alert)
    }

    func testReturnsNilWhenPendingButLastSuccessIsRecent() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: now.addingTimeInterval(-30 * 60),
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 3,
            pendingPotholeMarkCount: 0,
            pendingPhotoCount: 0
        )

        XCTAssertNil(alert, "30 minutes since last success is healthy and should not nag")
    }

    func testReturnsWarningWhenLastSuccessIsOver4Hours() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: now.addingTimeInterval(-5 * 3_600),
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 2,
            pendingPotholeMarkCount: 1,
            pendingPhotoCount: 0
        )

        XCTAssertEqual(alert?.severity, .warning)
        XCTAssertTrue(alert?.title.contains("5h") ?? false)
        XCTAssertTrue(alert?.detail.contains("3 items queued") ?? false)
    }

    func testReturnsDangerWhenLastSuccessIsOver24Hours() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: now.addingTimeInterval(-30 * 3_600),
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 5,
            pendingPotholeMarkCount: 2,
            pendingPhotoCount: 0
        )

        XCTAssertEqual(alert?.severity, .danger)
        XCTAssertTrue(alert?.title.contains("30h") ?? false, "Got: \(alert?.title ?? "")")
        XCTAssertTrue(alert?.detail.contains("7 item") ?? false, "Got: \(alert?.detail ?? "")")
    }

    func testReturnsWarningWhenSomethingPendingButNeverUploaded() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: nil,
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 1,
            pendingPotholeMarkCount: 0,
            pendingPhotoCount: 0
        )

        XCTAssertEqual(alert?.severity, .warning)
        XCTAssertTrue(alert?.title.contains("Nothing has uploaded yet") ?? false)
    }

    func testReturnsDangerWhenAnyFailedPermanent() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: now,
            uploadStatusSummary: UploadQueueStatusSummary(
                pendingReadingCount: 0,
                failedPermanentBatchCount: 2,
                nextRetryAt: nil,
                lastSuccessfulUploadAt: now
            ),
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 0,
            pendingPotholeMarkCount: 0,
            pendingPhotoCount: 0
        )

        XCTAssertEqual(alert?.severity, .danger)
        XCTAssertTrue(alert?.title.contains("uploads failed") ?? false)
        XCTAssertTrue(alert?.detail.contains("2 items") ?? false)
    }

    func testFailedPermanentTakesPrecedenceOverStalenessCheck() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: now.addingTimeInterval(-100 * 3_600),
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: PotholeActionStatusSummary(
                pendingCount: 0,
                failedPermanentCount: 1,
                nextRetryAt: nil,
                lastSuccessfulUploadAt: nil
            ),
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 5,
            pendingPotholeMarkCount: 0,
            pendingPhotoCount: 0
        )

        // Both conditions are true; the failed-permanent one is the more
        // actionable signal for the user, so it must win.
        XCTAssertEqual(alert?.severity, .danger)
        XCTAssertTrue(alert?.title.contains("failed") ?? false)
    }

    func testHandlesSingularItemPhrasingForOneQueuedRow() {
        let alert = SettingsView.uploadHealthAlert(
            now: now,
            lastSuccessfulUploadAt: nil,
            uploadStatusSummary: .empty,
            potholeActionStatusSummary: .empty,
            potholePhotoStatusSummary: .empty,
            pendingTripUploadCount: 0,
            pendingPotholeMarkCount: 1,
            pendingPhotoCount: 0
        )

        XCTAssertNotNil(alert)
        // Singular "item" not "items"
        XCTAssertTrue(alert?.detail.contains("1 item queued") ?? false)
    }
}
