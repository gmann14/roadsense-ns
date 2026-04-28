import Foundation
import Observation

enum FeedbackCategory: String, CaseIterable, Identifiable, Sendable {
    case bug
    case feature
    case mapIssue = "map_issue"
    case potholeIssue = "pothole_issue"
    case privacySafety = "privacy_safety"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bug:
            return "Bug or crash"
        case .feature:
            return "Feature suggestion"
        case .mapIssue:
            return "Map or road data issue"
        case .potholeIssue:
            return "Pothole issue"
        case .privacySafety:
            return "Privacy or safety concern"
        case .other:
            return "Something else"
        }
    }
}

enum FeedbackSubmissionStatus: Equatable, Sendable {
    case idle
    case submitting
    case submitted
    case validationFailed([String: String])
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case networkError(String)
    case serverError(statusCode: Int)
}

@MainActor
protocol FeedbackSubmitting {
    func submit(_ request: FeedbackSubmissionRequest) async throws -> FeedbackSubmissionResult
}

@MainActor
struct FeedbackSubmissionAPIClient: FeedbackSubmitting {
    let apiClient: APIClient

    func submit(_ request: FeedbackSubmissionRequest) async throws -> FeedbackSubmissionResult {
        try await apiClient.submitFeedback(request)
    }
}

@MainActor
@Observable
final class FeedbackComposerModel: Identifiable {
    static let messageMinimumLength = 8
    static let messageMaximumLength = 4000

    let id = UUID()

    private let submitter: FeedbackSubmitting
    private let queue: FeedbackQueue?
    private let source: String
    private let route: String?
    private let locale: String?

    var category: FeedbackCategory
    var message: String
    var replyEmail: String
    var contactConsent: Bool
    private(set) var status: FeedbackSubmissionStatus
    private(set) var queuedForRetryCount: Int = 0

    init(
        submitter: FeedbackSubmitting,
        queue: FeedbackQueue? = nil,
        source: String = "ios",
        route: String? = nil,
        locale: String? = Locale.current.identifier,
        initialCategory: FeedbackCategory = .bug
    ) {
        self.submitter = submitter
        self.queue = queue
        self.source = source
        self.route = route
        self.locale = locale
        self.category = initialCategory
        self.message = ""
        self.replyEmail = ""
        self.contactConsent = false
        self.status = .idle
        self.queuedForRetryCount = queue?.pendingCount ?? 0
    }

    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedReplyEmail: String {
        replyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        guard status != .submitting else { return false }
        guard trimmedMessage.count >= Self.messageMinimumLength else { return false }
        guard trimmedMessage.count <= Self.messageMaximumLength else { return false }
        if contactConsent && !FeedbackComposerModel.isValidEmail(trimmedReplyEmail) {
            return false
        }
        if !trimmedReplyEmail.isEmpty && !FeedbackComposerModel.isValidEmail(trimmedReplyEmail) {
            return false
        }
        return true
    }

    var characterCountLabel: String {
        "\(trimmedMessage.count)/\(Self.messageMaximumLength)"
    }

    func reset() {
        message = ""
        replyEmail = ""
        contactConsent = false
        status = .idle
    }

    func submit() async {
        guard canSubmit else { return }

        status = .submitting

        let request = FeedbackSubmissionRequest(
            source: source,
            category: category.rawValue,
            message: trimmedMessage,
            replyEmail: trimmedReplyEmail.isEmpty ? nil : trimmedReplyEmail,
            contactConsent: contactConsent,
            route: route,
            locale: locale
        )

        // Persist the submission BEFORE the network call. If the user kills
        // the app mid-submit (or the network drops + the request never
        // returns), the next composer open or app foreground will retry it.
        let pendingID = UUID()
        let persisted = PersistedFeedbackSubmission(
            id: pendingID,
            request: PersistedFeedbackRequest(request)
        )
        queue?.enqueue(persisted)
        queuedForRetryCount = queue?.pendingCount ?? 0

        do {
            let result = try await submitter.submit(request)
            switch result {
            case .accepted:
                queue?.markSubmitted(id: pendingID)
                status = .submitted
            case let .validationFailed(fieldErrors, _):
                // Server says this payload will never succeed; drop it from
                // the queue so we don't retry forever.
                queue?.markSubmitted(id: pendingID)
                status = .validationFailed(fieldErrors)
            case let .rateLimited(retryAfterSeconds, _):
                queue?.recordFailure(
                    id: pendingID,
                    message: "Rate-limited"
                )
                status = .rateLimited(retryAfterSeconds: retryAfterSeconds)
            case let .serverError(statusCode, _):
                queue?.recordFailure(
                    id: pendingID,
                    message: "Server error \(statusCode)"
                )
                status = .serverError(statusCode: statusCode)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            queue?.recordFailure(id: pendingID, message: message)
            status = .networkError(message)
        }

        queuedForRetryCount = queue?.pendingCount ?? 0
    }

    /// Drains pending submissions through the API. Safe to call on composer
    /// init or app foreground — silent on success, surfaces a banner on partial
    /// failure.
    func retryPending() async {
        guard let queue, queue.pendingCount > 0 else { return }

        let result = await FeedbackQueueDrainer.drain(
            queue: queue,
            submitter: submitter
        )
        queuedForRetryCount = queue.pendingCount

        if result.submitted > 0, status == .idle {
            status = .submitted
        }
    }

    static func isValidEmail(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        // \A and \z are absolute anchors; ^ and $ in NSRegularExpression match end-of-line by
        // default, which would silently accept a trailing newline that the server would reject.
        guard let regex = try? NSRegularExpression(pattern: "\\A[^\\s@]+@[^\\s@]+\\.[^\\s@]+\\z") else {
            return false
        }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, options: [], range: range) != nil
    }
}
