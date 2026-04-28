import Foundation
import XCTest
@testable import RoadSense_NS

@MainActor
final class FeedbackQueueTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "FeedbackQueueTests-\(UUID().uuidString)")!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        try await super.tearDown()
    }

    func testEmptyQueueReturnsNoItems() {
        let queue = FeedbackQueue(defaults: defaults)
        XCTAssertEqual(queue.pending(), [])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testEnqueueAndReadBack() {
        let queue = FeedbackQueue(defaults: defaults)
        let item = makeItem(message: "Map froze when marking a pothole.")

        queue.enqueue(item)

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.pending().first?.id, item.id)
        XCTAssertEqual(queue.pending().first?.request.message, "Map froze when marking a pothole.")
    }

    func testEnqueueDeduplicatesByID() {
        let queue = FeedbackQueue(defaults: defaults)
        let item = makeItem(message: "First version of the message.")
        queue.enqueue(item)

        var updated = item
        updated.attemptCount = 5
        updated.lastError = "rate-limited"
        queue.enqueue(updated)

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.pending().first?.attemptCount, 5)
        XCTAssertEqual(queue.pending().first?.lastError, "rate-limited")
    }

    func testMarkSubmittedRemovesItem() {
        let queue = FeedbackQueue(defaults: defaults)
        let keep = makeItem(message: "I want to keep this one in the queue.")
        let drop = makeItem(message: "This one will be marked submitted.")
        queue.enqueue(keep)
        queue.enqueue(drop)

        queue.markSubmitted(id: drop.id)

        XCTAssertEqual(queue.pending().map(\.id), [keep.id])
    }

    func testRecordFailureBumpsAttemptCountAndStoresError() {
        let queue = FeedbackQueue(defaults: defaults)
        let item = makeItem(message: "Network was offline when I tried to send.")
        queue.enqueue(item)

        queue.recordFailure(
            id: item.id,
            message: "no internet",
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let stored = queue.pending().first
        XCTAssertEqual(stored?.attemptCount, 1)
        XCTAssertEqual(stored?.lastError, "no internet")
        XCTAssertEqual(stored?.lastAttemptAt, Date(timeIntervalSince1970: 1_780_000_000))
    }

    func testRecordFailureForUnknownIdIsANoOp() {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "Should remain untouched after the no-op."))

        queue.recordFailure(id: UUID(), message: "phantom", now: Date())

        XCTAssertEqual(queue.pending().first?.attemptCount, 0)
        XCTAssertNil(queue.pending().first?.lastError)
    }

    func testQueuePersistsAcrossInstances() {
        let firstInstance = FeedbackQueue(defaults: defaults)
        let item = makeItem(message: "This needs to survive an app restart.")
        firstInstance.enqueue(item)

        let secondInstance = FeedbackQueue(defaults: defaults)
        XCTAssertEqual(secondInstance.pendingCount, 1)
        XCTAssertEqual(secondInstance.pending().first?.request.message, "This needs to survive an app restart.")
    }

    func testClearEmptiesTheQueue() {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "Going to be wiped."))
        queue.clear()
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testDrainerSubmitsPendingAndClearsOnAccept() async {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "First queued message to send."))
        queue.enqueue(makeItem(message: "Second queued message to send."))

        let submitter = StubFeedbackSubmitter(result: .accepted(id: "x", requestID: "req"))
        let result = await FeedbackQueueDrainer.drain(queue: queue, submitter: submitter)

        XCTAssertEqual(result.submitted, 2)
        XCTAssertEqual(result.stillPending, 0)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testDrainerLeavesItemsOnNetworkFailure() async {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "Should stay queued after a network drop."))

        let submitter = StubFeedbackSubmitter(error: URLError(.notConnectedToInternet))
        let result = await FeedbackQueueDrainer.drain(queue: queue, submitter: submitter)

        XCTAssertEqual(result.submitted, 0)
        XCTAssertEqual(result.stillPending, 1)
        XCTAssertEqual(result.networkErrors, 1)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.pending().first?.attemptCount, 1)
    }

    func testDrainerDropsItemRejectedAsValidationError() async {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "Server says this payload will never work."))

        let submitter = StubFeedbackSubmitter(
            result: .validationFailed(
                fieldErrors: ["message": "must be at least 8 characters"],
                requestID: "req"
            )
        )
        let result = await FeedbackQueueDrainer.drain(queue: queue, submitter: submitter)

        XCTAssertEqual(result.submitted, 0)
        XCTAssertEqual(result.serverRejected, 1)
        XCTAssertEqual(queue.pendingCount, 0, "validation failures get dropped, not retried forever")
    }

    func testDrainerKeepsItemOnRateLimit() async {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "Hit the per-IP rate limit on submit."))

        let submitter = StubFeedbackSubmitter(result: .rateLimited(retryAfterSeconds: 600, requestID: "req"))
        let result = await FeedbackQueueDrainer.drain(queue: queue, submitter: submitter)

        XCTAssertEqual(result.submitted, 0)
        XCTAssertEqual(result.stillPending, 1)
        XCTAssertEqual(queue.pendingCount, 1)
    }

    func testComposerSubmitPersistsAndClearsOnAccept() async {
        let queue = FeedbackQueue(defaults: defaults)
        let submitter = StubFeedbackSubmitter(result: .accepted(id: "x", requestID: "req"))
        let composer = FeedbackComposerModel(submitter: submitter, queue: queue)
        composer.message = "This should persist briefly then clear on success."

        await composer.submit()

        XCTAssertEqual(composer.status, .submitted)
        XCTAssertEqual(queue.pendingCount, 0, "successful submission is removed from the queue")
        XCTAssertEqual(composer.queuedForRetryCount, 0)
    }

    func testComposerSubmitKeepsItemOnNetworkFailure() async {
        let queue = FeedbackQueue(defaults: defaults)
        let submitter = StubFeedbackSubmitter(error: URLError(.notConnectedToInternet))
        let composer = FeedbackComposerModel(submitter: submitter, queue: queue)
        composer.message = "Network was unreachable when I tapped Send."

        await composer.submit()

        guard case .networkError = composer.status else {
            return XCTFail("Expected networkError status, got \(composer.status)")
        }
        XCTAssertEqual(queue.pendingCount, 1, "failed submission survives in the queue")
        XCTAssertEqual(composer.queuedForRetryCount, 1)
    }

    func testComposerInitReportsExistingQueueCount() {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "From a previous app session."))
        let submitter = StubFeedbackSubmitter()

        let composer = FeedbackComposerModel(submitter: submitter, queue: queue)

        XCTAssertEqual(composer.queuedForRetryCount, 1)
    }

    func testComposerRetryPendingDrainsAndClearsCount() async {
        let queue = FeedbackQueue(defaults: defaults)
        queue.enqueue(makeItem(message: "Stale message from a prior drive."))
        let submitter = StubFeedbackSubmitter(result: .accepted(id: "x", requestID: "req"))
        let composer = FeedbackComposerModel(submitter: submitter, queue: queue)
        XCTAssertEqual(composer.queuedForRetryCount, 1)

        await composer.retryPending()

        XCTAssertEqual(composer.queuedForRetryCount, 0)
        XCTAssertEqual(submitter.recordedCalls.count, 1)
    }

    private func makeItem(message: String) -> PersistedFeedbackSubmission {
        PersistedFeedbackSubmission(
            request: PersistedFeedbackRequest(
                source: "ios",
                category: "bug",
                message: message,
                replyEmail: nil,
                contactConsent: false,
                route: "Settings",
                locale: "en-CA"
            )
        )
    }
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
        if let error { throw error }
        return result ?? .accepted(id: "default", requestID: "req")
    }
}
