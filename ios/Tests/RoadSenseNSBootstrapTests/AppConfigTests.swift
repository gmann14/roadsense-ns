import Foundation
import Testing
@testable import RoadSenseNSBootstrap

struct AppConfigTests {
    @Test
    func parsesStagingConfigDictionary() throws {
        let config = try AppConfig.fromDictionary([
            "APP_ENV": "STAGING",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "SENTRY_DSN": "https://public@sentry.example/1",
            "ENABLE_SENTRY": "YES",
            "APP_GROUP_IDENTIFIER": "group.ca.roadsense.ios"
        ])

        #expect(config.environment == .staging)
        #expect(config.apiBaseURL.absoluteString == "https://roadsense.ca")
        #expect(config.functionsBaseURL.absoluteString == "https://roadsense.ca/functions/v1")
        #expect(config.mapboxAccessToken == "pk.test-token")
        #expect(config.supabaseAnonKey == "anon.test-key")
        #expect(config.sentryDSN == "https://public@sentry.example/1")
        #expect(config.enableSentry == true)
        #expect(config.appGroupIdentifier == "group.ca.roadsense.ios")
        #expect(config.enablePotholePhotos == true)
        #expect(config.enableMapFollowPuckOnLaunch == false)
    }

    @Test
    func disablesSentryByDefaultEvenWithDSN() throws {
        let config = try AppConfig.fromDictionary([
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "SENTRY_DSN": "https://public@sentry.example/1"
        ])

        #expect(config.sentryDSN == "https://public@sentry.example/1")
        #expect(config.enableSentry == false)
    }

    @Test
    func parsesSentryFlag() throws {
        let disabled = try AppConfig.fromDictionary([
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "SENTRY_DSN": "https://public@sentry.example/1",
            "ENABLE_SENTRY": "NO"
        ])
        #expect(disabled.enableSentry == false)

        let bogus = try AppConfig.fromDictionary([
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "SENTRY_DSN": "https://public@sentry.example/1",
            "ENABLE_SENTRY": "maybe"
        ])
        #expect(bogus.enableSentry == false)
    }

    @Test
    func parsesPotholePhotoFlag() throws {
        let disabled = try AppConfig.fromDictionary([
            "APP_ENV": "STAGING",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "ENABLE_POTHOLE_PHOTOS": "NO"
        ])
        #expect(disabled.enablePotholePhotos == false)

        let explicitlyEnabled = try AppConfig.fromDictionary([
            "APP_ENV": "STAGING",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "ENABLE_POTHOLE_PHOTOS": "YES"
        ])
        #expect(explicitlyEnabled.enablePotholePhotos == true)

        let bogus = try AppConfig.fromDictionary([
            "APP_ENV": "STAGING",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "ENABLE_POTHOLE_PHOTOS": "maybe"
        ])
        #expect(bogus.enablePotholePhotos == true)
    }

    @Test
    func parsesMapFollowPuckLaunchFlag() throws {
        let disabled = try AppConfig.fromDictionary([
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH": "NO"
        ])
        #expect(disabled.enableMapFollowPuckOnLaunch == false)

        let explicitlyEnabled = try AppConfig.fromDictionary([
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH": "YES"
        ])
        #expect(explicitlyEnabled.enableMapFollowPuckOnLaunch == true)

        let bogus = try AppConfig.fromDictionary([
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
            "ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH": "maybe"
        ])
        #expect(bogus.enableMapFollowPuckOnLaunch == false)
    }

    @Test
    func rejectsMissingOrInvalidFields() {
        #expect(throws: AppConfigError.missingOrInvalid("APP_ENV")) {
            try AppConfig.fromDictionary([
                "API_BASE_URL": "https://roadsense.ca",
                "MAPBOX_ACCESS_TOKEN": "pk.test-token",
                "SUPABASE_ANON_KEY": "anon.test-key"
            ])
        }

        #expect(throws: AppConfigError.missingOrInvalid("API_BASE_URL")) {
            try AppConfig.fromDictionary([
                "APP_ENV": "LOCAL",
                "API_BASE_URL": "not-a-url",
                "MAPBOX_ACCESS_TOKEN": "pk.test-token",
                "SUPABASE_ANON_KEY": "anon.test-key"
            ])
        }

        #expect(throws: AppConfigError.missingOrInvalid("MAPBOX_ACCESS_TOKEN")) {
            try AppConfig.fromDictionary([
                "APP_ENV": "PRODUCTION",
                "API_BASE_URL": "https://roadsense.ca",
                "SUPABASE_ANON_KEY": "anon.test-key"
            ])
        }

        #expect(throws: AppConfigError.missingOrInvalid("SUPABASE_ANON_KEY")) {
            try AppConfig.fromDictionary([
                "APP_ENV": "PRODUCTION",
                "API_BASE_URL": "https://roadsense.ca",
                "MAPBOX_ACCESS_TOKEN": "pk.test-token"
            ])
        }
    }
}
