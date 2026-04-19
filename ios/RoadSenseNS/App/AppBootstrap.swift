import Foundation

enum AppBootstrap {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
}
