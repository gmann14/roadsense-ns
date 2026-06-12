import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Upload policy")
struct UploadPolicyTests {
    @Test("200 succeeds without retry")
    func okResponseSucceeds() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 200, retryAfterSeconds: nil), attemptNumber: 1)

        #expect(disposition == .succeeded)
    }

    @Test("400 fails permanently")
    func validationFailureStopsRetries() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 400, retryAfterSeconds: nil), attemptNumber: 1)

        #expect(disposition == .failedPermanent)
    }

    @Test("400 fails permanently regardless of attempt count")
    func validationFailureStopsRetriesAtAnyAttempt() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 400, retryAfterSeconds: nil), attemptNumber: 9)

        #expect(disposition == .failedPermanent)
    }

    @Test("404 retries for upload routes")
    func missingRouteRetries() {
        let first = UploadPolicy.evaluate(.http(statusCode: 404, retryAfterSeconds: nil), attemptNumber: 1)
        let fifth = UploadPolicy.evaluate(.http(statusCode: 404, retryAfterSeconds: nil), attemptNumber: 5)

        #expect(first == .retry(afterSeconds: 1))
        #expect(fifth == .retry(afterSeconds: 16))
    }

    @Test("429 respects Retry-After when present")
    func rateLimitUsesRetryAfter() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 429, retryAfterSeconds: 3600), attemptNumber: 2)

        #expect(disposition == .retry(afterSeconds: 3600))
    }

    @Test("429 falls back to 60 seconds when header is missing")
    func rateLimitFallsBackToSixtySeconds() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 429, retryAfterSeconds: nil), attemptNumber: 2)

        #expect(disposition == .retry(afterSeconds: 60))
    }

    @Test("503 respects Retry-After when present (feature-disabled pause)")
    func serviceUnavailableUsesRetryAfter() {
        // The gateway's photos_disabled response sends Retry-After: 21600 so
        // queued photos probe a few times a day instead of hourly.
        let disposition = UploadPolicy.evaluate(.http(statusCode: 503, retryAfterSeconds: 21_600), attemptNumber: 3)

        #expect(disposition == .retry(afterSeconds: 21_600))
    }

    @Test("503 with Retry-After never becomes permanent")
    func serviceUnavailableWithRetryAfterNeverBecomesPermanent() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 503, retryAfterSeconds: 21_600), attemptNumber: 50)

        #expect(disposition == .retry(afterSeconds: 21_600))
    }

    @Test("5xx uses exponential backoff")
    func serverErrorsUseExponentialBackoff() {
        let first = UploadPolicy.evaluate(.http(statusCode: 503, retryAfterSeconds: nil), attemptNumber: 1)
        let second = UploadPolicy.evaluate(.http(statusCode: 503, retryAfterSeconds: nil), attemptNumber: 2)
        let fifth = UploadPolicy.evaluate(.http(statusCode: 503, retryAfterSeconds: nil), attemptNumber: 5)

        #expect(first == .retry(afterSeconds: 1))
        #expect(second == .retry(afterSeconds: 2))
        #expect(fifth == .retry(afterSeconds: 16))
    }

    @Test("network errors use exponential backoff")
    func networkErrorsUseExponentialBackoff() {
        let disposition = UploadPolicy.evaluate(.networkError, attemptNumber: 3)

        #expect(disposition == .retry(afterSeconds: 4))
    }

    @Test("an offline burst never exhausts attempts into permanent failure")
    func networkErrorsNeverBecomePermanent() {
        let sixth = UploadPolicy.evaluate(.networkError, attemptNumber: 6)
        let fiftieth = UploadPolicy.evaluate(.networkError, attemptNumber: 50)

        #expect(sixth == .retry(afterSeconds: 32))
        #expect(fiftieth == .retry(afterSeconds: UploadPolicy.maxRetryDelaySeconds))
    }

    @Test("server errors never become permanent")
    func serverErrorsNeverBecomePermanent() {
        let disposition = UploadPolicy.evaluate(.http(statusCode: 503, retryAfterSeconds: nil), attemptNumber: 6)

        #expect(disposition == .retry(afterSeconds: 32))
    }

    @Test("retry backoff is capped at one hour")
    func retryBackoffIsCapped() {
        let networkError = UploadPolicy.evaluate(.networkError, attemptNumber: 13)
        let serverError = UploadPolicy.evaluate(.http(statusCode: 500, retryAfterSeconds: nil), attemptNumber: 40)

        #expect(networkError == .retry(afterSeconds: UploadPolicy.maxRetryDelaySeconds))
        #expect(serverError == .retry(afterSeconds: UploadPolicy.maxRetryDelaySeconds))
    }
}
