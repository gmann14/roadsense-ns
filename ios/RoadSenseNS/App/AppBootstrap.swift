import Foundation

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
}
