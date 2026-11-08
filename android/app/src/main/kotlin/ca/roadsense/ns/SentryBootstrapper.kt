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
                scrubOrDrop(event)
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
    // Optional quotes cover JSON-style text such as `"lat": "44.6488"`.
    private val NAMED_COORDINATE = Regex(
        """(?i)\b(lat|lng|lon|latitude|longitude)\b("?\s*[=:]\s*"?)-?\d+(\.\d+)?""",
    )
    // Any lone number in coordinate range with 4+ decimals (about 11 m of
    // precision) is treated as a coordinate, whatever surrounds it.
    private val PRECISE_DECIMAL = Regex("""(?<![\d.])-?\d{1,3}\.\d{4,}(?![\d.])""")
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
        .replace(PRECISE_DECIMAL, "[number]")

    private fun isSensitiveKey(key: String): Boolean =
        key.lowercase().replace("_", "").replace("-", "") in SENSITIVE_KEYS

    /** Returns a scrubbed copy: sensitive keys dropped, strings scrubbed,
     *  nested maps copied recursively. Copies rather than mutates, because
     *  nested maps from SDK integrations may be read-only. */
    private fun scrubbedCopy(map: Map<*, *>): MutableMap<String, Any?> {
        val copy = HashMap<String, Any?>()
        map.forEach { (rawKey, value) ->
            val key = rawKey?.toString() ?: return@forEach
            if (isSensitiveKey(key)) return@forEach
            copy[key] = scrubValue(value)
        }
        return copy
    }

    private fun scrubValue(value: Any?): Any? = when (value) {
        is String -> scrubText(value)
        is Map<*, *> -> scrubbedCopy(value)
        is Collection<*> -> value.map(::scrubValue)
        else -> value
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
            val data = crumb.data
            val keys = data.keys.toList()
            val scrubbed = scrubbedCopy(data)
            keys.forEach(crumb::removeData)
            scrubbed.forEach { (key, value) -> if (value != null) crumb.setData(key, value) }
        }

        event.extras?.keys?.toList()?.forEach { key ->
            val value = event.getExtra(key)
            when {
                isSensitiveKey(key) -> event.removeExtra(key)
                value != null -> scrubValue(value)?.let { event.setExtra(key, it) }
            }
        }

        event.tags?.keys?.toList()?.forEach { key ->
            val value = event.getTag(key)
            if (isSensitiveKey(key)) event.removeTag(key)
            else if (value != null) event.setTag(key, scrubText(value))
        }

        val contexts = event.contexts
        contexts.keys.toList().forEach { key ->
            val value = contexts[key]
            when {
                isSensitiveKey(key) -> contexts.remove(key)
                value is Map<*, *> -> contexts[key] = scrubbedCopy(value)
                value is String -> contexts[key] = scrubText(value)
            }
        }

        event.message?.let { message ->
            message.message = message.message?.let(::scrubText)
            message.formatted = message.formatted?.let(::scrubText)
            message.params = message.params?.map(::scrubText)
        }

        // Sentry flattens chained causes into this list, so causes are covered.
        event.exceptions?.forEach { exception ->
            exception.value = exception.value?.let(::scrubText)
        }

        // No user block at all: sendDefaultPii is off, and nothing we send
        // should tie an event to a person.
        event.user = null
        event.request = null
        return event
    }

    /** Fails closed: if scrubbing throws for any reason, the event is
     *  dropped rather than sent unscrubbed. */
    internal fun scrubOrDrop(event: SentryEvent): SentryEvent? = try {
        scrub(event)
    } catch (error: Exception) {
        runCatching { AppLog.warn("dropped a Sentry event the scrubber could not process: ${error.javaClass.simpleName}") }
        null
    }
}
