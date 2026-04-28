import Foundation

public struct AppConfig: Equatable, Sendable {
    public let environment: AppEnvironment
    public let apiBaseURL: URL
    public let mapboxAccessToken: String
    public let supabaseAnonKey: String
    public let sentryDSN: String?
    public let appGroupIdentifier: String?
    public let enablePotholePhotos: Bool

    public init(
        environment: AppEnvironment,
        apiBaseURL: URL,
        mapboxAccessToken: String,
        supabaseAnonKey: String,
        sentryDSN: String? = nil,
        appGroupIdentifier: String? = nil,
        enablePotholePhotos: Bool = true
    ) {
        self.environment = environment
        self.apiBaseURL = apiBaseURL
        self.mapboxAccessToken = mapboxAccessToken
        self.supabaseAnonKey = supabaseAnonKey
        self.sentryDSN = sentryDSN?.nilIfEmpty
        self.appGroupIdentifier = appGroupIdentifier?.nilIfEmpty
        self.enablePotholePhotos = enablePotholePhotos
    }

    public var functionsBaseURL: URL {
        apiBaseURL.appendingPathComponent("functions/v1", isDirectory: false)
    }

    public static func fromDictionary(_ values: [String: String]) throws -> AppConfig {
        guard let environment = AppEnvironment(buildSetting: values["APP_ENV"]) else {
            throw AppConfigError.missingOrInvalid("APP_ENV")
        }

        guard let apiBaseURLString = values["API_BASE_URL"]?.nilIfEmpty,
              let apiBaseURL = URL(string: apiBaseURLString),
              let scheme = apiBaseURL.scheme,
              let host = apiBaseURL.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            throw AppConfigError.missingOrInvalid("API_BASE_URL")
        }

        guard let mapboxAccessToken = values["MAPBOX_ACCESS_TOKEN"]?.nilIfEmpty else {
            throw AppConfigError.missingOrInvalid("MAPBOX_ACCESS_TOKEN")
        }

        guard let supabaseAnonKey = values["SUPABASE_ANON_KEY"]?.nilIfEmpty else {
            throw AppConfigError.missingOrInvalid("SUPABASE_ANON_KEY")
        }

        return AppConfig(
            environment: environment,
            apiBaseURL: apiBaseURL,
            mapboxAccessToken: mapboxAccessToken,
            supabaseAnonKey: supabaseAnonKey,
            sentryDSN: values["SENTRY_DSN"],
            appGroupIdentifier: values["APP_GROUP_IDENTIFIER"],
            enablePotholePhotos: parseBool(values["ENABLE_POTHOLE_PHOTOS"], default: true)
        )
    }
}

private func parseBool(_ value: String?, default defaultValue: Bool) -> Bool {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else {
        return defaultValue
    }
    switch raw.lowercased() {
    case "yes", "true", "1": return true
    case "no", "false", "0": return false
    default: return defaultValue
    }
}

public enum AppConfigError: Error, Equatable, LocalizedError {
    case missingOrInvalid(String)

    public var errorDescription: String? {
        switch self {
        case let .missingOrInvalid(key):
            return "Missing or invalid config value: \(key)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
