package ca.roadsense.ns.permissions

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * Single source of truth for "what permissions are granted right now?". The
 * onboarding screens (A12-4) and the foreground service start path read
 * this; tests stub it via the `PermissionsState` snapshot rather than
 * mocking ContextCompat.
 */
data class PermissionsState(
    val fineLocation: Boolean,
    val backgroundLocation: Boolean,
    val activityRecognition: Boolean,
    val postNotifications: Boolean,
    val camera: Boolean,
) {
    /** Minimum needed to start a drive. Background location upgrade is
     *  asked after the first drive (matches iOS Always upgrade pattern). */
    val canStartDrive: Boolean get() = fineLocation && activityRecognition && postNotifications

    /** Background drives only run with this set; matches iOS "Always" tier. */
    val canRunBackgroundDrive: Boolean get() = canStartDrive && backgroundLocation
}

class PermissionsCoordinator(private val context: Context) {
    fun snapshot(): PermissionsState = PermissionsState(
        fineLocation = isGranted(Manifest.permission.ACCESS_FINE_LOCATION),
        backgroundLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            isGranted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else true,
        activityRecognition = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            isGranted(Manifest.permission.ACTIVITY_RECOGNITION)
        } else true,
        postNotifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            isGranted(Manifest.permission.POST_NOTIFICATIONS)
        } else true,
        camera = isGranted(Manifest.permission.CAMERA),
    )

    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
