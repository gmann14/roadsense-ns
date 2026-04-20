import Foundation
import SwiftUI

enum AppBootstrap {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["ROAD_SENSE_UI_TESTS"] == "1"
    }

    static func loadConfig(bundle: Bundle = .main) -> AppConfig {
        let keys = [
            "APP_ENV",
            "API_BASE_URL",
            "MAPBOX_ACCESS_TOKEN",
            "SENTRY_DSN",
            "APP_GROUP_IDENTIFIER",
        ]

        let values = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, bundle.object(forInfoDictionaryKey: key) as? String ?? "")
        })

        do {
            return try AppConfig.fromDictionary(values)
        } catch {
            fatalError("Invalid app configuration: \(error.localizedDescription)")
        }
    }

    static func defaultsForCurrentProcess() -> UserDefaults {
        guard isRunningTests else {
            return .standard
        }

        let environment = ProcessInfo.processInfo.environment
        let scenario = environment["ROAD_SENSE_TEST_SCENARIO"] ?? "default"
        let suiteName = "ca.roadsense.ios.tests.\(scenario)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        return defaults
    }

    static func dynamicTypeSizeOverride() -> DynamicTypeSize? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawValue = environment["ROAD_SENSE_DYNAMIC_TYPE_SIZE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        switch rawValue.lowercased() {
        case "xsmall":
            return .xSmall
        case "small":
            return .small
        case "medium":
            return .medium
        case "large":
            return .large
        case "xlarge":
            return .xLarge
        case "xxlarge":
            return .xxLarge
        case "xxxlarge":
            return .xxxLarge
        case "accessibility1":
            return .accessibility1
        case "accessibility2":
            return .accessibility2
        case "accessibility3":
            return .accessibility3
        case "accessibility4":
            return .accessibility4
        case "accessibility5":
            return .accessibility5
        default:
            return nil
        }
    }
}
