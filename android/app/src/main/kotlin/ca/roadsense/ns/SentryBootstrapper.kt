package ca.roadsense.ns

import android.content.Context
import ca.roadsense.ns.api.AppConfig
import io.sentry.SentryEvent
import io.sentry.android.core.SentryAndroid

/**
 * Manual Sentry bootstrap. Mirrors `ios/RoadSenseNS/App/SentryBootstrapper.swift`:
 *   - guard on a non-blank DSN (sideload + CI builds have no DSN)
 *   - `sendDefaultPii = false` to avoid auto-capturing the IP/device user
 *   - scrub any precise-location breadcrumbs in `beforeSend` so a leak in
 *     instrumentation code can never publish a user coordinate to Sentry
 *
 * Auto-init is disabled in `AndroidManifest.xml` (`io.sentry.auto-init=false`)
 * so this bootstrap is the only entry point. Calling it twice is a no-op —
 * SentryAndroid.init replaces the existing options atomically.
 */
object SentryBootstrapper {
    fun bootstrap(context: Context, config: AppConfig) {
        val dsn = config.sentryDSN?.takeIf { it.isNotBlank() } ?: return

        SentryAndroid.init(context) { options ->
            options.dsn = dsn
            options.environment = config.environment.name.lowercase()
            options.release = BuildConfig.APP_VERSION_NAME + "+" + BuildConfig.APP_VERSION_CODE
            options.isSendDefaultPii = false
            // `enabled` defaults to true; we keep it explicit so the next
            // engineer can see how to feature-flag the SDK without dropping
            // the import.
            options.isEnabled = true
            options.beforeSend = io.sentry.SentryOptions.BeforeSendCallback { event, _ ->
                scrubLocationData(event)
            }
        }
    }

    /** Strip any breadcrumbs or extras that look like raw coordinates. We
     *  never want a stack trace + a precise lat/lng landing in the same
     *  Sentry event, even by accident. iOS's bootstrapper doesn't do this
     *  yet; this is defense-in-depth on the Android side because foreground
     *  service logs are far chattier on Android than iOS. */
    internal fun scrubLocationData(event: SentryEvent): SentryEvent {
        event.breadcrumbs?.forEach { crumb ->
            val data = crumb.data ?: return@forEach
            listOf("lat", "lng", "latitude", "longitude", "accuracy_m", "accuracyMeters").forEach { key ->
                data.remove(key)
            }
        }
        return event
    }
}
