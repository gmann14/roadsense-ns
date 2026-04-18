import Foundation

public enum AppEnvironment: String, CaseIterable, Codable, Sendable {
    case local = "LOCAL"
    case staging = "STAGING"
    case production = "PRODUCTION"

    public init?(buildSetting: String?) {
        guard let buildSetting else {
            return nil
        }

        self.init(rawValue: buildSetting.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    public var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .staging:
            return "Staging"
        case .production:
            return "Production"
        }
    }
}
