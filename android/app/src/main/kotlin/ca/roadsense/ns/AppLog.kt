package ca.roadsense.ns

import android.util.Log
import io.sentry.Sentry

/**
 * The app's only logging entry point. Messages must never contain
 * coordinates, device tokens, emails or feedback text: logcat is readable by
 * anyone with adb, and errors are forwarded to Sentry (where
 * `SentryBootstrapper.scrub` is a second line of defence, not the first).
 */
object AppLog {
    private const val TAG = "RoadSense"

    fun info(message: String) {
        Log.i(TAG, message)
    }

    fun warn(message: String, error: Throwable? = null) {
        Log.w(TAG, message, error)
    }

    /** Logs and reports [error] to Sentry when Sentry is configured. */
    fun error(message: String, error: Throwable) {
        Log.e(TAG, message, error)
        try {
            if (Sentry.isEnabled()) Sentry.captureException(error)
        } catch (reportFailure: Exception) {
            // Crash reporting must never take the app down with it.
            Log.w(TAG, "could not forward error to Sentry", reportFailure)
        }
    }
}
