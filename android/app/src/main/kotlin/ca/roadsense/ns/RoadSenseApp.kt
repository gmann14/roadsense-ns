package ca.roadsense.ns

import android.app.Application
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import ca.roadsense.ns.upload.UploadDrainWorker
import java.util.concurrent.TimeUnit

/**
 * Application entry point. Schedules the upload heartbeat when the process
 * starts; foreground drive-end uploads still enqueue one-shot work.
 */
class RoadSenseApp : Application() {
    override fun onCreate() {
        super.onCreate()
        scheduleUploadHeartbeat()
    }

    private fun scheduleUploadHeartbeat() {
        val request = PeriodicWorkRequestBuilder<UploadDrainWorker>(15, TimeUnit.MINUTES)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .addTag(UploadDrainWorker.TAG)
            .build()

        try {
            WorkManager.getInstance(this).enqueueUniquePeriodicWork(
                UploadDrainWorker.PERIODIC_WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        } catch (_: IllegalStateException) {
            // Robolectric/unit-test processes do not initialize WorkManager.
            // Production app startup should keep running even if scheduling is
            // unavailable; drive-end one-shot uploads can still be queued.
        }
    }
}
