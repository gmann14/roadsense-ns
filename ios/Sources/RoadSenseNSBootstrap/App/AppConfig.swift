import Foundation

public struct AppConfig: Equatable, Sendable {
    public let environment: AppEnvironment
    public let apiBaseURL: URL
    public let mapboxAccessToken: String
    public let sentryDSN: String?
    public let appGroupIdentifier: String?

    public init(
        environment: AppEnvironment,
        apiBaseURL: URL,
        mapboxAccessToken: String,
        sentryDSN: String? = nil,
        appGroupIdentifier: String? = nil
    ) {
        self.environment = environment
        self.apiBaseURL = apiBaseURL
        self.mapboxAccessToken = mapboxAccessToken
        self.sentryDSN = sentryDSN?.nilIfEmpty
        self.appGroupIdentifier = appGroupIdentifier?.nilIfEmpty
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

        return AppConfig(
            environment: environment,
            apiBaseURL: apiBaseURL,
            mapboxAccessToken: mapboxAccessToken,
            sentryDSN: values["SENTRY_DSN"],
            appGroupIdentifier: values["APP_GROUP_IDENTIFIER"]
        )
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
