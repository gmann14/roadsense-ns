import Foundation

/// A pending feedback submission persisted across app launches.
///
/// Stored as JSON in UserDefaults rather than SwiftData because the volume is
/// tiny (a tester might queue 1–3 unsent items before a successful drain;
/// realistic ceiling is dozens, not thousands), and avoiding a schema
/// migration keeps the offline-queue change small.
struct PersistedFeedbackSubmission: Codable, Equatable, Identifiable {
    let id: UUID
    let request: PersistedFeedbackRequest
    let queuedAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        request: PersistedFeedbackRequest,
        queuedAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.request = request
        self.queuedAt = queuedAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

struct PersistedFeedbackRequest: Codable, Equatable {
    let source: String
    let category: String
    let message: String
    let replyEmail: String?
    let contactConsent: Bool
    let route: String?
    let locale: String?

    init(
        source: String,
        category: String,
        message: String,
        replyEmail: String?,
        contactConsent: Bool,
        route: String?,
        locale: String?
    ) {
        self.source = source
        self.category = category
        self.message = message
        self.replyEmail = replyEmail
        self.contactConsent = contactConsent
        self.route = route
        self.locale = locale
    }

    init(_ request: FeedbackSubmissionRequest) {
        self.source = request.source
        self.category = request.category
        self.message = request.message
        self.replyEmail = request.replyEmail
        self.contactConsent = request.contactConsent
        self.route = request.route
        self.locale = request.locale
    }

    func toRequest() -> FeedbackSubmissionRequest {
        FeedbackSubmissionRequest(
            source: source,
            category: category,
            message: message,
            replyEmail: replyEmail,
            contactConsent: contactConsent,
            route: route,
            locale: locale
        )
    }
}

@MainActor
final class FeedbackQueue {
    static let storageKey = "ca.roadsense.ios.feedback-queue"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func enqueue(_ submission: PersistedFeedbackSubmission) {
        var items = pending()
        // De-dup by id in case the same submission is re-enqueued mid-retry.
        items.removeAll { $0.id == submission.id }
        items.append(submission)
        write(items)
    }

    func pending() -> [PersistedFeedbackSubmission] {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([PersistedFeedbackSubmission].self, from: data)
        } catch {
            return []
        }
    }

    var pendingCount: Int { pending().count }

    func markSubmitted(id: UUID) {
        var items = pending()
        items.removeAll { $0.id == id }
        write(items)
    }

    func recordFailure(id: UUID, message: String, now: Date = Date()) {
        var items = pending()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        var item = items[index]
        item.attemptCount += 1
        item.lastAttemptAt = now
        item.lastError = message
        items[index] = item
        write(items)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func write(_ items: [PersistedFeedbackSubmission]) {
        if items.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            // Best-effort persistence; if encoding fails we'd rather lose the
            // queue entry than crash. The composer still has the form text in
            // memory if the user is actively retrying.
        }
    }
}

@MainActor
struct FeedbackQueueDrainResult: Equatable {
    let submitted: Int
    let stillPending: Int
    let serverRejected: Int
    let networkErrors: Int
}

@MainActor
enum FeedbackQueueDrainer {
    /// Attempts to submit each pending item once. Returns a summary so the
    /// caller (composer or AppModel foreground hook) can decide whether to
    /// surface a banner or stay silent.
    static func drain(
        queue: FeedbackQueue,
        submitter: FeedbackSubmitting,
        now: () -> Date = Date.init
    ) async -> FeedbackQueueDrainResult {
        var submitted = 0
        var stillPending = 0
        var serverRejected = 0
        var networkErrors = 0

        for item in queue.pending() {
            do {
                let result = try await submitter.submit(item.request.toRequest())
                switch result {
                case .accepted:
                    queue.markSubmitted(id: item.id)
                    submitted += 1
                case let .validationFailed(fieldErrors, _):
                    // Server says this payload will never be acceptable; drop
                    // it so the queue doesn't sit forever on a malformed item.
                    queue.markSubmitted(id: item.id)
                    serverRejected += 1
                    let summary = fieldErrors.values.sorted().joined(separator: " · ")
                    queue.recordFailure(
                        id: item.id,
                        message: "Server rejected: \(summary)",
                        now: now()
                    )
                case let .rateLimited(retryAfterSeconds, _):
                    queue.recordFailure(
                        id: item.id,
                        message: "Rate-limited" + (retryAfterSeconds.map { ", retry in \(Int($0))s" } ?? ""),
                        now: now()
                    )
                    stillPending += 1
                case let .serverError(statusCode, _):
                    queue.recordFailure(
                        id: item.id,
                        message: "Server error \(statusCode)",
                        now: now()
                    )
                    stillPending += 1
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                queue.recordFailure(id: item.id, message: message, now: now())
                stillPending += 1
                networkErrors += 1
            }
        }

        return FeedbackQueueDrainResult(
            submitted: submitted,
            stillPending: stillPending,
            serverRejected: serverRejected,
            networkErrors: networkErrors
        )
    }
}
