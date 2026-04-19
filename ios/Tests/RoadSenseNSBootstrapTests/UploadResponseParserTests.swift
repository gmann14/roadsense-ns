import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct UploadResponseParserTests {
    @Test
    func parsesSuccessBody() throws {
        let body = """
        {
          "batch_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "accepted": 12,
          "rejected": 3,
          "duplicate": true,
          "rejected_reasons": {
            "low_quality": 2,
            "no_segment_match": 1
          }
        }
        """.data(using: .utf8)!

        let result = try UploadResponseParser.parse(statusCode: 200, body: body)

        guard case let .success(response) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(response.accepted == 12)
        #expect(response.rejected == 3)
        #expect(response.duplicate)
        #expect(response.rejectedReasons["low_quality"] == 2)
    }

    @Test
    func parsesRateLimitHeaderAndErrorEnvelope() throws {
        let body = """
        {
          "error": "rate_limited",
          "details": {
            "limit": "device_hourly"
          }
        }
        """.data(using: .utf8)!

        let result = try UploadResponseParser.parse(
            statusCode: 429,
            headers: ["Retry-After": "3600"],
            body: body
        )

        guard case let .failure(outcome, envelope) = result else {
            Issue.record("Expected failure")
            return
        }

        #expect(outcome == .http(statusCode: 429, retryAfterSeconds: 3600))
        #expect(envelope?.error == "rate_limited")
        #expect(envelope?.details?["limit"] == "device_hourly")
    }

    @Test
    func handlesNonJsonFailureBody() throws {
        let result = try UploadResponseParser.parse(
            statusCode: 503,
            body: Data("temporarily unavailable".utf8)
        )

        guard case let .failure(outcome, envelope) = result else {
            Issue.record("Expected failure")
            return
        }

        #expect(outcome == .http(statusCode: 503, retryAfterSeconds: nil))
        #expect(envelope == nil)
    }
}
