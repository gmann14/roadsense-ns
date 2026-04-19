import Foundation

enum UploadBatchJSONCodec {
    static func encodeRejectedReasons(_ reasons: [String: Int]) -> String? {
        guard !reasons.isEmpty,
              let data = try? JSONEncoder().encode(reasons) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func decodeRejectedReasons(_ json: String?) -> [String: Int] {
        guard let json,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }

        return decoded
    }
}
