import Foundation
import OSLog

struct RoadSenseLogger {
    private let logger: Logger

    init(category: String) {
        self.logger = Logger(subsystem: "ca.roadsense.ios", category: category)
    }

    static let app = RoadSenseLogger(category: "app")
    static let upload = RoadSenseLogger(category: "upload")

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    func uploadSucceeded(batchID: UUID, accepted: Int, rejected: Int, duplicate: Bool) {
        logger.info("upload_succeeded batch=\(batchID.uuidString, privacy: .public) accepted=\(accepted, privacy: .public) rejected=\(rejected, privacy: .public) duplicate=\(duplicate, privacy: .public)")
    }

    func uploadFailed(batchID: UUID, attemptResult: UploadAttemptResult, message: String?) {
        logger.error("upload_failed batch=\(batchID.uuidString, privacy: .public) result=\(String(describing: attemptResult), privacy: .public) message=\(message ?? "unknown", privacy: .public)")
    }
}
