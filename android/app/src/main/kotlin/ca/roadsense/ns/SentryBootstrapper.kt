package ca.roadsense.ns

import android.content.Context
import ca.roadsense.ns.api.AppConfig
import io.sentry.SentryEvent
import io.sentry.android.core.SentryAndroid

/**
 * Manual Sentry bootstrap. Mirrors `ios/RoadSenseNS/App/SentryBootstrapper.swift`:
 *   - guard on a non-blank DSN (sideload + CI builds have no DSN)
 *   - `sendDefaultPii = false` to avoid auto-capturing the IP/device user
 *   - scrub every free-form part of the event in `beforeSend` (see [scrub])
 *     so a leak in instrumentation code can never publish a coordinate, a
 *     device token or an email address to Sentry
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
            options.release = BuildConfig.VERSION_NAME + "+" + BuildConfig.VERSION_CODE
            options.isSendDefaultPii = false
            // `enabled` defaults to true; we keep it explicit so the next
            // engineer can see how to feature-flag the SDK without dropping
            // the import.
            options.isEnabled = true
            options.beforeSend = io.sentry.SentryOptions.BeforeSendCallback { event, _ ->
                scrub(event)
            }
        }
    }

    /** Keys whose values are dropped wherever they appear (compared
     *  case-insensitively with `_` and `-` removed). */
    private val SENSITIVE_KEYS = setOf(
        "lat", "lng", "lon", "long", "latitude", "longitude",
        "accuracym", "accuracymeters", "gpsaccuracym",
        "location", "coordinate", "coordinates", "coords",
        "devicetoken", "token", "apikey", "authorization",
        "email", "replyemail", "feedback", "feedbackmessage",
    )

    private val COORDINATE_PAIR = Regex("""-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}""")
    private val NAMED_COORDINATE = Regex(
        """(?i)\b(lat|lng|lon|latitude|longitude)\b(\s*[=:]\s*)-?\d+(\.\d+)?""",
    )
    private val UUID_PATTERN = Regex(
        """(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b""",
    )
    private val EMAIL_PATTERN = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")
    private val JWT_PATTERN = Regex("""eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*""")

    /** Redacts coordinates, UUIDs (device tokens are UUIDs), emails and
     *  JWT-shaped keys from free text. */
    internal fun scrubText(text: String): String = text
        .replace(JWT_PATTERN, "[jwt]")
        .replace(EMAIL_PATTERN, "[email]")
        .replace(UUID_PATTERN, "[uuid]")
        .replace(COORDINATE_PAIR, "[coords]")
        .replace(NAMED_COORDINATE) { "${it.groupValues[1]}${it.groupValues[2]}[redacted]" }

    private fun isSensitiveKey(key: String): Boolean =
        key.lowercase().replace("_", "").replace("-", "") in SENSITIVE_KEYS

    /** Removes sensitive keys and scrubs string values, recursing into
     *  nested maps (Sentry contexts are maps of maps). */
    @Suppress("UNCHECKED_CAST")
    private fun scrubMap(map: MutableMap<String, Any?>) {
        map.keys.filter(::isSensitiveKey).forEach { map.remove(it) }
        map.entries.forEach { entry ->
            when (val value = entry.value) {
                is String -> entry.setValue(scrubText(value))
                is MutableMap<*, *> -> scrubMap(value as MutableMap<String, Any?>)
                else -> Unit
            }
        }
    }

    /**
     * Defence in depth for the rule in [AppLog]: an event must never carry a
     * precise location, a device token or contact details, even if some code
     * path (or a future Sentry integration) puts one there by accident.
     * Covers breadcrumbs, extras, tags, untyped contexts, the message, the
     * exception values and the user/request blocks.
     */
    internal fun scrub(event: SentryEvent): SentryEvent {
        event.breadcrumbs?.forEach { crumb ->
            crumb.message = crumb.message?.let(::scrubText)
            crumb.data?.let { data ->
                @Suppress("UNCHECKED_CAST")
                scrubMap(data as MutableMap<String, Any?>)
            }
        }

        event.extras?.keys?.toList()?.forEach { key ->
            val value = event.getExtra(key)
            when {
                isSensitiveKey(key) -> event.removeExtra(key)
                value is String -> event.setExtra(key, scrubText(value))
                value is MutableMap<*, *> -> {
                    @Suppress("UNCHECKED_CAST")
                    scrubMap(value as MutableMap<String, Any?>)
                }
            }
        }

        event.tags?.keys?.toList()?.forEach { key ->
            val value = event.getTag(key)
            if (isSensitiveKey(key)) event.removeTag(key)
            else if (value != null) event.setTag(key, scrubText(value))
        }

        val contexts = event.contexts
        contexts.keys.filter(::isSensitiveKey).forEach { contexts.remove(it) }
        contexts.values.forEach { value ->
            if (value is MutableMap<*, *>) {
                @Suppress("UNCHECKED_CAST")
                scrubMap(value as MutableMap<String, Any?>)
            }
        }

        event.message?.let { message ->
            message.message = message.message?.let(::scrubText)
            message.formatted = message.formatted?.let(::scrubText)
            message.params = message.params?.map(::scrubText)
        }

        event.exceptions?.forEach { exception ->
            exception.value = exception.value?.let(::scrubText)
        }

        // No user block at all: sendDefaultPii is off, and nothing we send
        // should tie an event to a person.
        event.user = null
        event.request = null
        return event
    }
}
