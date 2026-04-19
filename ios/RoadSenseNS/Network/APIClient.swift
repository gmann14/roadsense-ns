import Foundation

enum APIClientError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "invalid_response"
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
}
