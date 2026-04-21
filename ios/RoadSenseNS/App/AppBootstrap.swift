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
            "SUPABASE_ANON_KEY",
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

    static func formatMapLoadError(
        _ message: String,
        bundle: Bundle = .main
    ) -> String {
        let token = (bundle.object(forInfoDictionaryKey: "MAPBOX_ACCESS_TOKEN") as? String) ?? ""
        let normalizedMessage = message.lowercased()

        if token.hasPrefix("pk.placeholder") {
            return "Mapbox token missing or invalid. Add a real token in ios/Config/RoadSenseNS.Local.secrets.xcconfig as MAPBOX_ACCESS_TOKEN = pk..."
        }

        if normalizedMessage.contains("missing authorization header") {
            return "Community map layer is unauthorized. Add SUPABASE_ANON_KEY to ios/Config/RoadSenseNS.Local.secrets.xcconfig."
        }

        if normalizedMessage.contains("invalid token") {
            return "Map request was unauthorized. Check MAPBOX_ACCESS_TOKEN and SUPABASE_ANON_KEY in ios/Config/RoadSenseNS.Local.secrets.xcconfig."
        }

        return message
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
