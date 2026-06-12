import Foundation

public enum UploadAttemptResult: Equatable, Sendable {
    case http(statusCode: Int, retryAfterSeconds: TimeInterval?)
    case networkError
}

public enum UploadDisposition: Equatable, Sendable {
    case succeeded
    case retry(afterSeconds: TimeInterval)
    case failedPermanent
}

public enum UploadPolicy {
    /// Upper bound for exponential retry backoff (1 hour). Transport-level
    /// failures (offline, timeout, connection refused) and transient server
    /// errors (5xx, missing route) never become `failedPermanent` — driving
    /// offline in rural coverage gaps is the core use case, so only an
    /// explicit server rejection (4xx validation) may strand a batch.
    public static let maxRetryDelaySeconds: TimeInterval = 3_600

    public static func evaluate(
        _ result: UploadAttemptResult,
        attemptNumber: Int
    ) -> UploadDisposition {
        switch result {
        case let .http(statusCode, _) where statusCode == 200:
            return .succeeded

        case let .http(statusCode, _) where statusCode == 400:
            return .failedPermanent

        case let .http(statusCode, _) where statusCode == 404:
            return .retry(afterSeconds: backoffDelay(attemptNumber: attemptNumber))

        case let .http(statusCode, retryAfterSeconds) where statusCode == 429:
            return .retry(afterSeconds: retryAfterSeconds ?? 60)

        case let .http(statusCode, _) where (500...599).contains(statusCode):
            return .retry(afterSeconds: backoffDelay(attemptNumber: attemptNumber))

        case .networkError:
            return .retry(afterSeconds: backoffDelay(attemptNumber: attemptNumber))

        default:
            return .failedPermanent
        }
    }

    private static func backoffDelay(attemptNumber: Int) -> TimeInterval {
        let exponent = min(max(attemptNumber - 1, 0), 16)
        return min(pow(2.0, Double(exponent)), maxRetryDelaySeconds)
    }
}
