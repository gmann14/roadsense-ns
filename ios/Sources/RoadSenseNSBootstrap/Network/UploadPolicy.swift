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
            return retryOrPermanent(attemptNumber: attemptNumber)

        case let .http(statusCode, retryAfterSeconds) where statusCode == 429:
            return .retry(afterSeconds: retryAfterSeconds ?? 60)

        case let .http(statusCode, _) where (500...599).contains(statusCode):
            return retryOrPermanent(attemptNumber: attemptNumber)

        case .networkError:
            return retryOrPermanent(attemptNumber: attemptNumber)

        default:
            return .failedPermanent
        }
    }

    private static func retryOrPermanent(attemptNumber: Int) -> UploadDisposition {
        guard attemptNumber <= 5 else {
            return .failedPermanent
        }

        let exponent = max(attemptNumber - 1, 0)
        let delay = pow(2.0, Double(exponent))
        return .retry(afterSeconds: delay)
    }
}
