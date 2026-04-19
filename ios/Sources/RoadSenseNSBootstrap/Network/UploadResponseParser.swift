import Foundation

public enum UploadResponseParsingResult: Equatable, Sendable {
    case success(UploadReadingsResponse)
    case failure(UploadAttemptResult, UploadErrorEnvelope?)
}

public enum UploadResponseParser {
    public static func parse(
        statusCode: Int,
        headers: [AnyHashable: Any] = [:],
        body: Data,
        decoder: JSONDecoder? = nil
    ) throws -> UploadResponseParsingResult {
        let decoder = decoder ?? UploadCodec.makeDecoder()

        if statusCode == 200 {
            let response = try decoder.decode(UploadReadingsResponse.self, from: body)
            return .success(response)
        }

        let errorEnvelope = try? decoder.decode(UploadErrorEnvelope.self, from: body)
        return .failure(
            .http(
                statusCode: statusCode,
                retryAfterSeconds: retryAfter(from: headers).map(TimeInterval.init)
            ),
            errorEnvelope
        )
    }

    private static func retryAfter(from headers: [AnyHashable: Any]) -> Int? {
        let value = headers.first { key, _ in
            String(describing: key).caseInsensitiveCompare("Retry-After") == .orderedSame
        }?.value

        switch value {
        case let seconds as Int:
            return seconds
        case let seconds as String:
            return Int(seconds)
        default:
            return nil
        }
    }
}
