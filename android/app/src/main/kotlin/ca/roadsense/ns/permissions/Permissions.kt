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
 * Only two runtime grants matter:
 * - location — requested as FINE + COARSE together (required since Android
 *   12, which lets the user pick "approximate"). Collection needs precise
 *   location: readings and drive starts require ≤ 20 m accuracy.
 * - notifications (Android 13+) — so the persistent "Recording road quality"
 *   notification is visible.
 *
 * Background location is deliberately absent: drives run in a
 * `location`-typed foreground service started from the visible app, which
 * keeps receiving location with the screen off.
 *
 * Compose surfaces query [PermissionState.snapshot] each time the user
 * re-enters the app so the status row reflects actual grants rather than
 * cached shared-preferences flags.
 */
data class PermissionState(
    val fineLocation: Boolean,
    val coarseLocation: Boolean,
    val notifications: Boolean,
) {
    /** Drives need precise location. */
    val canStartForegroundDrive: Boolean
        get() = fineLocation

    /** The user granted only "approximate" in the Android 12+ dialog. */
    val hasOnlyApproximateLocation: Boolean
        get() = coarseLocation && !fineLocation

    val missingForForeground: List<String>
        get() = buildList {
            if (!fineLocation) {
                add(
                    if (hasOnlyApproximateLocation) {
                        "Precise location (currently set to approximate)"
                    } else {
                        "Precise location"
                    },
                )
            }
        }

    companion object {
        fun snapshot(context: Context): PermissionState = PermissionState(
            fineLocation = isGranted(context, Manifest.permission.ACCESS_FINE_LOCATION),
            coarseLocation = isGranted(context, Manifest.permission.ACCESS_COARSE_LOCATION),
            notifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                isGranted(context, Manifest.permission.POST_NOTIFICATIONS)
            } else true,
        )

        /**
         * The single runtime request: FINE + COARSE location (Android 12+
         * rejects a FINE-only request) plus notifications on Android 13+.
         */
        fun foregroundLadder(): Array<String> = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.toTypedArray()

        private fun isGranted(context: Context, permission: String): Boolean =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }
}
