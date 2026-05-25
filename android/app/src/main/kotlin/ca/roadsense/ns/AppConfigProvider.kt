package ca.roadsense.ns

import ca.roadsense.ns.api.AppConfig
import ca.roadsense.ns.api.AppEnvironment

/**
 * Bridges generated `BuildConfig` fields (driven by the per-flavor properties
 * files in `android/config/`) to the typed `AppConfig` the rest of the
 * codebase consumes. Mirrors how iOS reads xcconfig values into `AppConfig`.
 */
object AppConfigProvider {
    fun current(): AppConfig {
        val env = AppEnvironment.fromBuildSetting(BuildConfig.APP_ENV.lowercase())
            ?: error("Unknown APP_ENV ${'$'}{BuildConfig.APP_ENV}; check the active product flavor.")
        return AppConfig(
            environment = env,
            apiBaseURL = BuildConfig.API_BASE_URL,
            mapboxAccessToken = BuildConfig.MAPBOX_ACCESS_TOKEN,
            supabaseAnonKey = BuildConfig.SUPABASE_ANON_KEY,
            sentryDSN = BuildConfig.SENTRY_DSN.takeIf { it.isNotBlank() },
            enablePotholePhotos = BuildConfig.ENABLE_POTHOLE_PHOTOS,
        )
    }
}
