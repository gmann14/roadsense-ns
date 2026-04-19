import Foundation

enum APIClientError: LocalizedError {
    case invalidResponse
    case notFound
    case requestFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "invalid_response"
        case .notFound:
            return "not_found"
        case let .requestFailed(statusCode, message):
            return message ?? "request_failed_\(statusCode)"
        }
    }
}

struct UploadAttemptSummary: Sendable {
    let result: UploadResponseParsingResult
}

final class APIClient {
    private let endpoints: Endpoints
    private let session: URLSession

    init(
        endpoints: Endpoints,
        session: URLSession = .shared
    ) {
        self.endpoints = endpoints
        self.session = session
    }

    func uploadReadings(
        batchID: UUID,
        deviceToken: String,
        readings: [UploadReadingPayload]
    ) async throws -> UploadAttemptSummary {
        let request = try UploadRequestFactory.makeRequest(
            endpoints: endpoints,
            batchID: batchID,
            deviceToken: deviceToken,
            readings: readings
        )
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let parsed = try UploadResponseParser.parse(
            statusCode: httpResponse.statusCode,
            headers: httpResponse.allHeaderFields,
            body: data
        )
        return UploadAttemptSummary(result: parsed)
    }

    func fetchSegmentDetail(id: UUID) async throws -> SegmentDetailResponse {
        var request = URLRequest(url: endpoints.segmentDetailURL(id: id))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let parsed = try SegmentDetailResponseParser.parse(
            statusCode: httpResponse.statusCode,
            body: data
        )

        switch parsed {
        case let .found(segment):
            return segment
        case .notFound:
            throw APIClientError.notFound
        case let .failure(statusCode, errorEnvelope):
            throw APIClientError.requestFailed(
                statusCode: statusCode,
                message: errorEnvelope?.error
            )
        }
    }
}
