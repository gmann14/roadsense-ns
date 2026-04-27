import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct FeedbackPayloadEncodingTests {
    @Test
    func encodesAllFieldsAsSnakeCase() throws {
        let payload = FeedbackSubmissionPayload(
            source: "ios",
            category: "bug",
            message: "Map froze when I tapped Mark pothole twice in a row.",
            replyEmail: "tester@example.com",
            contactConsent: true,
            appVersion: "0.3.0 (101)",
            platform: "iOS 17.4.1",
            locale: "en-CA",
            route: "Settings"
        )

        let data = try JSONEncoder().encode(payload)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["source"] as? String == "ios")
        #expect(json["category"] as? String == "bug")
        #expect(json["message"] as? String == "Map froze when I tapped Mark pothole twice in a row.")
        #expect(json["reply_email"] as? String == "tester@example.com")
        #expect(json["contact_consent"] as? Bool == true)
        #expect(json["app_version"] as? String == "0.3.0 (101)")
        #expect(json["platform"] as? String == "iOS 17.4.1")
        #expect(json["locale"] as? String == "en-CA")
        #expect(json["route"] as? String == "Settings")
    }

    @Test
    func omitsOptionalFieldsThatAreNil() throws {
        let payload = FeedbackSubmissionPayload(
            source: "web",
            category: "feature",
            message: "Add dark mode for the public map.",
            replyEmail: nil,
            contactConsent: false,
            appVersion: "web",
            platform: "web",
            locale: nil,
            route: nil
        )

        let data = try JSONEncoder().encode(payload)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // JSONEncoder default behavior: nil Optionals are omitted, not encoded as null.
        // The Edge Function treats missing and null identically for these fields.
        #expect(json["reply_email"] == nil)
        #expect(json["locale"] == nil)
        #expect(json["route"] == nil)
        #expect(json["source"] as? String == "web")
        #expect(json["contact_consent"] as? Bool == false)
    }

    @Test
    func decodesAcceptedResponseFromServer() throws {
        let body = #"{"id":"00000000-0000-0000-0000-000000000abc","request_id":"req-123"}"#
            .data(using: .utf8)!

        let decoded = try JSONDecoder().decode(FeedbackSubmissionAcceptedResponse.self, from: body)

        #expect(decoded.id == "00000000-0000-0000-0000-000000000abc")
        #expect(decoded.requestID == "req-123")
    }

    @Test
    func decodesValidationErrorFromServer() throws {
        let body = """
        {
          "error": "validation_failed",
          "message": "Feedback payload failed validation.",
          "request_id": "req-400",
          "field_errors": {
            "message": "must be at least 8 characters"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(FeedbackValidationErrorResponse.self, from: body)

        #expect(decoded.error == "validation_failed")
        #expect(decoded.requestID == "req-400")
        #expect(decoded.fieldErrors["message"] == "must be at least 8 characters")
    }

    @Test
    func endpointsBuildFeedbackURL() {
        let config = AppConfig(
            environment: .local,
            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
            mapboxAccessToken: "pk.test-token",
            supabaseAnonKey: "anon.test-key"
        )
        let endpoints = Endpoints(config: config)

        #expect(endpoints.feedbackURL.absoluteString == "http://127.0.0.1:54321/functions/v1/feedback")
    }
}
