package ca.roadsense.ns.api

enum class AppEnvironment(val buildSetting: String) {
    LOCAL("local"),
    STAGING("staging"),
    PRODUCTION("production");

    companion object {
        fun fromBuildSetting(value: String?): AppEnvironment? =
            value?.let { setting -> entries.firstOrNull { it.buildSetting == setting } }
    }
}

class AppConfigError(message: String) : RuntimeException(message)

data class AppConfig(
    val environment: AppEnvironment,
    val apiBaseURL: String,
    val mapboxAccessToken: String,
    val supabaseAnonKey: String,
    val sentryDSN: String? = null,
    val enablePotholePhotos: Boolean = true,
) {
    init {
        require(apiBaseURL.startsWith("http://") || apiBaseURL.startsWith("https://")) {
            "apiBaseURL must use http or https"
        }
    }

    val functionsBaseURL: String
        get() = apiBaseURL.trimEnd('/') + "/functions/v1"

    companion object {
        fun fromMap(values: Map<String, String>): AppConfig {
            val environment = AppEnvironment.fromBuildSetting(values["APP_ENV"])
                ?: throw AppConfigError("missing or invalid APP_ENV")
            val apiBaseURL = values["API_BASE_URL"]?.takeIf { it.isNotBlank() }
                ?: throw AppConfigError("missing or invalid API_BASE_URL")
            val mapboxAccessToken = values["MAPBOX_ACCESS_TOKEN"]?.takeIf { it.isNotBlank() }
                ?: throw AppConfigError("missing or invalid MAPBOX_ACCESS_TOKEN")
            val supabaseAnonKey = values["SUPABASE_ANON_KEY"]?.takeIf { it.isNotBlank() }
                ?: throw AppConfigError("missing or invalid SUPABASE_ANON_KEY")
            return AppConfig(
                environment = environment,
                apiBaseURL = apiBaseURL,
                mapboxAccessToken = mapboxAccessToken,
                supabaseAnonKey = supabaseAnonKey,
                sentryDSN = values["SENTRY_DSN"]?.takeIf { it.isNotBlank() },
            )
        }
    }
}
