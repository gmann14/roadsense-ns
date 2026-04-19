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

    @Test("failing beyond five attempts becomes permanent")
    func maxAttemptsBecomePermanent() {
        let disposition = UploadPolicy.evaluate(.networkError, attemptNumber: 6)

        #expect(disposition == .failedPermanent)
    }
}
