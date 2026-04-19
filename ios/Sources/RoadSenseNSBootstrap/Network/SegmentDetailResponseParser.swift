import Foundation

public enum SegmentDetailResponseParsingResult: Equatable, Sendable {
    case found(SegmentDetailResponse)
    case notFound(UploadErrorEnvelope?)
    case failure(statusCode: Int, errorEnvelope: UploadErrorEnvelope?)
}

public enum SegmentDetailResponseParser {
    public static func parse(
        statusCode: Int,
        body: Data,
        decoder: JSONDecoder? = nil
    ) throws -> SegmentDetailResponseParsingResult {
        let decoder = decoder ?? UploadCodec.makeDecoder()

        if statusCode == 200 {
            return .found(try decoder.decode(SegmentDetailResponse.self, from: body))
        }

        let errorEnvelope = try? decoder.decode(UploadErrorEnvelope.self, from: body)
        if statusCode == 404 {
            return .notFound(errorEnvelope)
        }

        return .failure(statusCode: statusCode, errorEnvelope: errorEnvelope)
    }
}
