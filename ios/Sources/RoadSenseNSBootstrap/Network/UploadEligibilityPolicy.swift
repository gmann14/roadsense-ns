import Foundation

public enum NetworkPathStatus: Equatable, Sendable {
    case satisfied
    case unsatisfied
}

public struct NetworkPathSnapshot: Equatable, Sendable {
    public let status: NetworkPathStatus
    public let isExpensive: Bool

    public init(status: NetworkPathStatus, isExpensive: Bool) {
        self.status = status
        self.isExpensive = isExpensive
    }
}

public enum UploadEligibilityPolicy {
    public static func shouldUpload(
        pendingCount: Int,
        network: NetworkPathSnapshot,
        nextAttemptAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        guard network.status == .satisfied else {
            return false
        }

        guard pendingCount > 0 else {
            return false
        }

        if let nextAttemptAt, nextAttemptAt > now {
            return false
        }

        return true
    }
}
