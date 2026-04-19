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
        allowCellularUpload: Bool
    ) -> Bool {
        guard network.status == .satisfied else {
            return false
        }

        if network.isExpensive, !allowCellularUpload, pendingCount < 100 {
            return false
        }

        return pendingCount > 0
    }
}
