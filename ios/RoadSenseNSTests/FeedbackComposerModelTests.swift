import Foundation
import XCTest
@testable import RoadSense_NS

@MainActor
final class FeedbackComposerModelTests: XCTestCase {
    func testCannotSubmitWhenMessageIsTooShort() {
        let submitter = StubFeedbackSubmitter()
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "no"

        XCTAssertFalse(model.canSubmit)
    }

    func testCannotSubmitWhenContactConsentLacksValidEmail() {
        let submitter = StubFeedbackSubmitter()
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "Map froze when I tapped Mark pothole twice in a row."
        model.contactConsent = true
        model.replyEmail = "definitely-not-an-email"

        XCTAssertFalse(model.canSubmit)
    }

    func testCannotSubmitWhenReplyEmailIsMalformed() {
        let submitter = StubFeedbackSubmitter()
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "Map froze when I tapped Mark pothole twice in a row."
        model.replyEmail = "missing-at-sign"

        XCTAssertFalse(model.canSubmit)
    }

    func testCanSubmitWithValidMessageAndOptionalEmail() {
        let submitter = StubFeedbackSubmitter()
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "Map froze when I tapped Mark pothole twice in a row."

        XCTAssertTrue(model.canSubmit)

        model.replyEmail = "tester@example.com"
        XCTAssertTrue(model.canSubmit)

        model.contactConsent = true
        XCTAssertTrue(model.canSubmit)
    }

    func testSubmitMarksSubmittedOnAcceptedResult() async {
        let submitter = StubFeedbackSubmitter(result: .accepted(id: "abc", requestID: "req-1"))
        let model = FeedbackComposerModel(
            submitter: submitter,
            route: "Settings",
            locale: "en-CA"
        )
        model.category = .featureSuggestionAlias
        model.message = "Please add a Drives list so I can review my last trips."

        await model.submit()

        XCTAssertEqual(model.status, .submitted)
        XCTAssertEqual(submitter.recordedCalls.count, 1)
        let call = submitter.recordedCalls[0]
        XCTAssertEqual(call.source, "ios")
        XCTAssertEqual(call.category, "feature")
        XCTAssertEqual(call.route, "Settings")
        XCTAssertEqual(call.locale, "en-CA")
        XCTAssertEqual(call.replyEmail, nil)
        XCTAssertFalse(call.contactConsent)
        XCTAssertEqual(call.message, "Please add a Drives list so I can review my last trips.")
    }

    func testSubmitSurfacesValidationErrorsFromServer() async {
        let submitter = StubFeedbackSubmitter(
            result: .validationFailed(
                fieldErrors: ["message": "must be at least 8 characters"],
                requestID: "req-2"
            )
        )
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "edge-case message that passes client checks but fails server"

        await model.submit()

        guard case let .validationFailed(errors) = model.status else {
            XCTFail("Expected validationFailed status, got \(model.status)")
            return
        }
        XCTAssertEqual(errors["message"], "must be at least 8 characters")
    }

    func testSubmitSurfacesRateLimitWithRetryAfter() async {
        let submitter = StubFeedbackSubmitter(
            result: .rateLimited(retryAfterSeconds: 1800, requestID: "req-3")
        )
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "Hit submit too many times in a row while testing."

        await model.submit()

        guard case let .rateLimited(retryAfterSeconds) = model.status else {
            XCTFail("Expected rateLimited status, got \(model.status)")
            return
        }
        XCTAssertEqual(retryAfterSeconds, 1800)
    }

    func testSubmitFallsBackToNetworkErrorOnThrow() async {
        let submitter = StubFeedbackSubmitter(error: URLError(.notConnectedToInternet))
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = "Cannot reach RoadSense from this network."

        await model.submit()

        guard case let .networkError(message) = model.status else {
            XCTFail("Expected networkError status, got \(model.status)")
            return
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testSubmitDoesNothingWhenCannotSubmit() async {
        let submitter = StubFeedbackSubmitter()
        let model = FeedbackComposerModel(submitter: submitter)
        model.message = ""

        await model.submit()

        XCTAssertEqual(submitter.recordedCalls.count, 0)
        XCTAssertEqual(model.status, .idle)
    }
}

private extension FeedbackCategory {
    static var featureSuggestionAlias: FeedbackCategory { .feature }
}

@MainActor
private final class StubFeedbackSubmitter: FeedbackSubmitting {
    private let result: FeedbackSubmissionResult?
    private let error: Error?
    private(set) var recordedCalls: [FeedbackSubmissionRequest] = []

    init(result: FeedbackSubmissionResult? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func submit(_ request: FeedbackSubmissionRequest) async throws -> FeedbackSubmissionResult {
        recordedCalls.append(request)
        if let error {
            throw error
        }
        if let result {
            return result
        }
        return .accepted(id: "00000000-0000-0000-0000-000000000abc", requestID: "req-default")
    }
}
