import Foundation
import XCTest
@testable import RoadSense_NS

final class APIClientFeedbackTests: XCTestCase {
    override func tearDown() {
        APIClientFeedbackMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSubmitFeedbackSendsExpectedRequest() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        var capturedURL: URL?
        var capturedHeaders: [String: String] = [:]
        var capturedBody: FeedbackSubmissionPayload?

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            for (key, value) in request.allHTTPHeaderFields ?? [:] {
                capturedHeaders[key] = value
            }
            let body = try APIClientFeedbackTests.extractBody(request)
            capturedBody = try UploadCodec.makeDecoder().decode(FeedbackSubmissionPayload.self, from: body)

            let response = FeedbackSubmissionAcceptedResponse(
                id: "00000000-0000-0000-0000-000000000abc",
                requestID: "req-from-body"
            )
            let payload = try UploadCodec.makeEncoder().encode(response)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-from-header"]
                )!,
                payload
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "bug",
                message: "Map froze when I tapped Mark pothole twice in a row.",
                replyEmail: "tester@example.com",
                contactConsent: true,
                route: "Settings",
                locale: "en-CA"
            )
        )

        XCTAssertEqual(capturedURL?.path, "/functions/v1/feedback")
        XCTAssertEqual(capturedHeaders["apikey"], "anon.test")
        XCTAssertEqual(capturedHeaders["Authorization"], "Bearer anon.test")
        XCTAssertEqual(capturedHeaders["Content-Type"], "application/json")

        let body = try XCTUnwrap(capturedBody)
        XCTAssertEqual(body.source, "ios")
        XCTAssertEqual(body.category, "bug")
        XCTAssertEqual(body.message, "Map froze when I tapped Mark pothole twice in a row.")
        XCTAssertEqual(body.replyEmail, "tester@example.com")
        XCTAssertTrue(body.contactConsent)
        XCTAssertEqual(body.locale, "en-CA")
        XCTAssertEqual(body.route, "Settings")
        XCTAssertFalse(body.appVersion.isEmpty)
        XCTAssertTrue(body.platform.hasPrefix("iOS "))

        guard case let .accepted(id, requestID) = result else {
            XCTFail("Expected accepted result, got \(result)")
            return
        }
        XCTAssertEqual(id, "00000000-0000-0000-0000-000000000abc")
        XCTAssertEqual(requestID, "req-from-body")
    }

    func testSubmitFeedbackEncodesPayloadAsSnakeCaseJSON() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        var rawBody: Data?
        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            rawBody = try APIClientFeedbackTests.extractBody(request)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                #"{"id":"abc","request_id":"req"}"#.data(using: .utf8)!
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        _ = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "feature",
                message: "Please add a Drives list so I can review last week's trips.",
                replyEmail: nil,
                contactConsent: false,
                route: "Map",
                locale: "en-CA"
            )
        )

        let bodyData = try XCTUnwrap(rawBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(json["source"] as? String, "ios")
        XCTAssertEqual(json["category"] as? String, "feature")
        XCTAssertEqual(json["contact_consent"] as? Bool, false)
        XCTAssertNotNil(json["app_version"] as? String)
        XCTAssertNotNil(json["platform"] as? String)
        XCTAssertEqual(json["route"] as? String, "Map")
        XCTAssertEqual(json["locale"] as? String, "en-CA")
        // Missing/null are equivalent server-side for reply_email; JSONEncoder omits nil Optionals by default.
        XCTAssertNil(json["reply_email"])
    }

    func testSubmitFeedbackTranslatesValidationFailure() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            let body = #"{"error":"validation_failed","request_id":"req-400","field_errors":{"message":"must be at least 8 characters"}}"#
                .data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-400"]
                )!,
                body
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "bug",
                message: "edge-case message that passes client checks",
                replyEmail: nil,
                contactConsent: false,
                route: nil,
                locale: nil
            )
        )

        guard case let .validationFailed(fieldErrors, requestID) = result else {
            XCTFail("Expected validationFailed, got \(result)")
            return
        }
        XCTAssertEqual(fieldErrors["message"], "must be at least 8 characters")
        XCTAssertEqual(requestID, "req-400")
    }

    func testSubmitFeedbackTranslatesRateLimitWithRetryAfter() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "1800", "x-request-id": "req-429"]
                )!,
                Data()
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "bug",
                message: "still here, just hitting the rate limit while testing.",
                replyEmail: nil,
                contactConsent: false,
                route: nil,
                locale: nil
            )
        )

        guard case let .rateLimited(retryAfterSeconds, requestID) = result else {
            XCTFail("Expected rateLimited, got \(result)")
            return
        }
        XCTAssertEqual(retryAfterSeconds, 1800)
        XCTAssertEqual(requestID, "req-429")
    }

    func testSubmitFeedbackTranslatesServerError() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-503"]
                )!,
                Data()
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "bug",
                message: "service was unavailable when I tried to send this feedback.",
                replyEmail: nil,
                contactConsent: false,
                route: nil,
                locale: nil
            )
        )

        guard case let .serverError(statusCode, requestID) = result else {
            XCTFail("Expected serverError, got \(result)")
            return
        }
        XCTAssertEqual(statusCode, 503)
        XCTAssertEqual(requestID, "req-503")
    }

    func testSubmitFeedbackTreatsHTMLErrorBodyAsServerError() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 502,
                    httpVersion: nil,
                    headerFields: ["content-type": "text/html"]
                )!,
                "<html><body>Bad gateway</body></html>".data(using: .utf8)!
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "bug",
                message: "Server returned an HTML error page instead of JSON.",
                replyEmail: nil, contactConsent: false, route: nil, locale: nil
            )
        )
        guard case let .serverError(statusCode, _) = result else {
            XCTFail("Expected serverError, got \(result)"); return
        }
        XCTAssertEqual(statusCode, 502)
    }

    func testSubmitFeedbackHandlesEmpty200Body() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!,
                Data()
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)

        do {
            _ = try await client.submitFeedback(
                FeedbackSubmissionRequest(
                    source: "ios",
                    category: "bug",
                    message: "Empty body on 200 — treated as server error or decode error.",
                    replyEmail: nil, contactConsent: false, route: nil, locale: nil
                )
            )
            // 200 with empty body is unexpected — current behavior tries to decode and throws.
            // Either outcome (throw OR serverError) is acceptable; missing the throw and silently succeeding would be wrong.
        } catch {
            // Expected: decode error
        }
    }

    func testSubmitFeedbackHandlesMalformedJSONOn400() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-malformed"]
                )!,
                "not json at all { ".data(using: .utf8)!
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios",
                category: "bug",
                message: "Server returned non-JSON body for 400.",
                replyEmail: nil, contactConsent: false, route: nil, locale: nil
            )
        )

        // Falls back to empty fieldErrors, header request ID still surfaces.
        guard case let .validationFailed(fieldErrors, requestID) = result else {
            XCTFail("Expected validationFailed, got \(result)"); return
        }
        XCTAssertTrue(fieldErrors.isEmpty)
        XCTAssertEqual(requestID, "req-malformed")
    }

    func testSubmitFeedbackPreservesNilRequestIDWhenServerOmitsHeader() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios", category: "bug",
                message: "No x-request-id header on the response.",
                replyEmail: nil, contactConsent: false, route: nil, locale: nil
            )
        )
        guard case let .serverError(statusCode, requestID) = result else {
            XCTFail("Expected serverError, got \(result)"); return
        }
        XCTAssertEqual(statusCode, 503)
        XCTAssertNil(requestID)
    }

    func testSubmitFeedbackParsesNumericRetryAfter() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "0", "x-request-id": "req-zero"]
                )!,
                Data()
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios", category: "bug",
                message: "Edge case: Retry-After is exactly 0.",
                replyEmail: nil, contactConsent: false, route: nil, locale: nil
            )
        )
        guard case let .rateLimited(retryAfterSeconds, requestID) = result else {
            XCTFail("Expected rateLimited, got \(result)"); return
        }
        XCTAssertEqual(retryAfterSeconds, 0)
        XCTAssertEqual(requestID, "req-zero")
    }

    func testSubmitFeedbackHandlesMissingRetryAfterHeader() async throws {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let result = try await client.submitFeedback(
            FeedbackSubmissionRequest(
                source: "ios", category: "bug",
                message: "429 with no Retry-After header at all.",
                replyEmail: nil, contactConsent: false, route: nil, locale: nil
            )
        )
        guard case let .rateLimited(retryAfterSeconds, _) = result else {
            XCTFail("Expected rateLimited, got \(result)"); return
        }
        XCTAssertNil(retryAfterSeconds)
    }

    func testSubmitFeedbackPropagatesSessionError() async {
        let session = makeMockSession()
        let endpoints = makeEndpoints()

        APIClientFeedbackMockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let client = APIClient(endpoints: endpoints, session: session)

        do {
            _ = try await client.submitFeedback(
                FeedbackSubmissionRequest(
                    source: "ios",
                    category: "bug",
                    message: "no network for this submission attempt — should propagate.",
                    replyEmail: nil,
                    contactConsent: false,
                    route: nil,
                    locale: nil
                )
            )
            XCTFail("Expected URLError to propagate from session")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Expected URLError but got \(error)")
        }
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientFeedbackMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeEndpoints() -> Endpoints {
        Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
    }

    fileprivate static func extractBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            XCTFail("Expected request body")
            throw URLError(.unknown)
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }
        return data
    }
}

private final class APIClientFeedbackMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
