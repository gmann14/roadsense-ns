import Foundation

public enum UploadRequestFactory {
    public static func makeRequest(
        endpoints: Endpoints,
        batchID: UUID,
        deviceToken: String,
        readings: [UploadReadingPayload],
        encoder: JSONEncoder? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoints.uploadReadingsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoints.config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(endpoints.config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let payload = UploadReadingsRequest(
            batchID: batchID,
            deviceToken: deviceToken,
            readings: readings
        )
        request.httpBody = try (encoder ?? UploadCodec.makeEncoder()).encode(payload)
        return request
    }
}

enum UploadCodec {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
