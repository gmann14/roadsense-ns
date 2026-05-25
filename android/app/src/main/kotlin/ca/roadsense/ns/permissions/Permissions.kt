package ca.roadsense.ns.permissions

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * Production permission ladder. Mirrors the matrix in
 * [docs/implementation/12-android-implementation.md] § Permissions + onboarding.
 *
 * Compose surfaces query [PermissionState.snapshot] each time the user
 * re-enters the app so the status row reflects actual grants rather than
 * cached shared-preferences flags.
 */
data class PermissionState(
    val fineLocation: Boolean,
    val backgroundLocation: Boolean,
    val activityRecognition: Boolean,
    val notifications: Boolean,
    val camera: Boolean,
) {
    /** Foreground drives need fine location + (on API 29+) activity-recognition. */
    val canStartForegroundDrive: Boolean
        get() = fineLocation && activityRecognition

    /** Background-survivable drives additionally need background location. */
    val canSurviveScreenOff: Boolean
        get() = canStartForegroundDrive && backgroundLocation

    val missingForForeground: List<String>
        get() = buildList {
            if (!fineLocation) add("Fine location")
            if (!activityRecognition) add("Activity recognition")
        }

    val missingForBackground: List<String>
        get() = buildList {
            if (!canStartForegroundDrive) addAll(missingForForeground)
            if (!backgroundLocation) add("Background location")
        }

    companion object {
        fun snapshot(context: Context): PermissionState = PermissionState(
            fineLocation = isGranted(context, Manifest.permission.ACCESS_FINE_LOCATION),
            backgroundLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                isGranted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            } else true,
            activityRecognition = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                isGranted(context, Manifest.permission.ACTIVITY_RECOGNITION)
            } else true,
            notifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                isGranted(context, Manifest.permission.POST_NOTIFICATIONS)
            } else true,
            camera = isGranted(context, Manifest.permission.CAMERA),
        )

        /**
         * The set of permissions to request first — fine-grained location
         * blocks everything else, so always lead with it. Activity recognition
         * + notifications are bundled because the rationale is shared.
         */
        fun foregroundLadder(): Array<String> = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(Manifest.permission.ACTIVITY_RECOGNITION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.toTypedArray()

        /**
         * Background location must be requested *after* fine location is
         * granted on API 30+ (Google Play policy), and Android system UI
         * routes the request to system Settings on API 30+ rather than a
         * runtime dialog. Returns the permission name; callers decide
         * whether to use the system dialog or open Settings directly.
         */
        fun backgroundLocationPermission(): String? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            } else null

        /**
         * Background location can only be requested via runtime dialog on
         * API 29 (Android 10). API 30+ requires the user to flip the
         * "Allow all the time" radio in app settings. The UI uses this to
         * decide between [requestPermissions] and a Settings deep-link.
         */
        fun mustRouteBackgroundToSettings(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

        private fun isGranted(context: Context, permission: String): Boolean =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }
}
