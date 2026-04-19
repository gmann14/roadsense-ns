import Foundation

enum UploadStatus: String, Codable, Sendable {
    case pending
    case inFlight
    case succeeded
    case failedPermanent
}
