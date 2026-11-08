package ca.roadsense.ns

import android.app.Application
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import ca.roadsense.ns.collection.CollectionService
import ca.roadsense.ns.upload.UploadDrainWorker
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

/**
 * Application entry point. On every process start:
 * - clears a "recording" flag a killed process may have left behind (no
 *   service can be running in a process that is only now starting);
 * - seals any drive session a crash or force-stop left open, so its readings
 *   are endpoint-trimmed and can upload (iOS parity: finalizeOpenDriveSessions);
 * - schedules the upload heartbeat.
 */
class RoadSenseApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SentryBootstrapper.bootstrap(this, AppConfigProvider.current())
        if (!CollectionService.isRunningInProcess) {
            CollectionService.clearRunningFlag(this)
        }
        finalizeOrphanedDrives()
        scheduleUploadHeartbeat()
    }

    private fun finalizeOrphanedDrives() {
        val container = RoadSenseContainer.from(this)
        container.appScope.launch {
            val sealed = container.driveSessions.finalizeOrphans()
            if (sealed.isNotEmpty()) {
                AppLog.info("sealed ${sealed.size} unfinished drive(s) from a previous run")
                UploadDrainWorker.enqueueOneShot(this@RoadSenseApp, manual = false)
            }
        }
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
        } catch (e: IllegalStateException) {
            AppLog.warn("upload heartbeat not scheduled", e)
            // Robolectric/unit-test processes do not initialize WorkManager.
            // Production app startup should keep running even if scheduling is
            // unavailable; drive-end one-shot uploads can still be queued.
        }
    }
}
