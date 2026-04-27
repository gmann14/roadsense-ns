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
    private let source: String
    private let route: String?
    private let locale: String?

    var category: FeedbackCategory
    var message: String
    var replyEmail: String
    var contactConsent: Bool
    private(set) var status: FeedbackSubmissionStatus

    init(
        submitter: FeedbackSubmitting,
        source: String = "ios",
        route: String? = nil,
        locale: String? = Locale.current.identifier,
        initialCategory: FeedbackCategory = .bug
    ) {
        self.submitter = submitter
        self.source = source
        self.route = route
        self.locale = locale
        self.category = initialCategory
        self.message = ""
        self.replyEmail = ""
        self.contactConsent = false
        self.status = .idle
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

        do {
            let result = try await submitter.submit(request)
            switch result {
            case .accepted:
                status = .submitted
            case let .validationFailed(fieldErrors, _):
                status = .validationFailed(fieldErrors)
            case let .rateLimited(retryAfterSeconds, _):
                status = .rateLimited(retryAfterSeconds: retryAfterSeconds)
            case let .serverError(statusCode, _):
                status = .serverError(statusCode: statusCode)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            status = .networkError(message)
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
