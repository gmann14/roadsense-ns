package ca.roadsense.ns.upload

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import ca.roadsense.ns.AppLog
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.api.NetworkPathSnapshot
import ca.roadsense.ns.api.NetworkPathStatus
import ca.roadsense.ns.data.room.FeedbackUploadState
import ca.roadsense.ns.data.room.PotholeActionUploadState
import ca.roadsense.ns.data.room.UploadBatchState
import ca.roadsense.ns.feedback.FeedbackQueueDrainer
import ca.roadsense.ns.feedback.FeedbackSubmitter
import ca.roadsense.ns.pothole.PotholeActionCoordinator
import ca.roadsense.ns.pothole.PotholeActionRpc
import ca.roadsense.ns.pothole.PotholePhotoBytesRpc
import ca.roadsense.ns.pothole.PotholePhotoCoordinator
import ca.roadsense.ns.pothole.PotholePhotoMetadataRpc
import kotlinx.coroutines.CancellationException
import java.time.Instant

/**
 * WorkManager entry point for the unified upload drain — readings, pothole
 * actions, and feedback all run from this single worker so the network
 * doesn't get hit by three concurrent workers fighting for the same row.
 *
 * Each run also prunes local data past the retention window
 * ([ca.roadsense.ns.api.RetentionPolicy]), so the periodic heartbeat is the
 * single place local data ages out.
 */
class UploadDrainWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = RoadSenseContainer.from(applicationContext)
        val db = container.database

        pruneLocalData(container)

        if (inputData.getBoolean(KEY_MANUAL, false)) {
            // "Upload now": the user asked for it, so don't make them wait
            // out a backoff a previous failure scheduled.
            db.uploadBatchDao().clearBackoff(UploadBatchState.PENDING)
            db.potholeActionDao().clearBackoff(PotholeActionUploadState.PENDING_UPLOAD.wireValue)
            db.feedbackDao().clearBackoff(FeedbackUploadState.PENDING.wireValue)
        }

        val readingCoordinator = UploadDrainCoordinator(
            database = db,
            readingDao = db.readingDao(),
            batchDao = db.uploadBatchDao(),
            uploadReadingsRpc = UploadReadingsRpc { request ->
                container.backendClient.uploadReadings(request)
            },
            deviceTokenProvider = { container.deviceTokenStore.currentToken() },
            clientAppVersion = container.clientAppVersion,
            clientOSVersion = container.clientOSVersion,
            privacyZones = { container.privacyZones() },
        )

        // Promote any pothole rows whose undo windows have elapsed before
        // the network drain runs. Mirrors iOS' coordinator that calls
        // `promoteExpiredUndos` on the same heartbeat.
        container.potholeActions.promoteExpiredUndos()

        val potholeCoordinator = PotholeActionCoordinator(
            dao = db.potholeActionDao(),
            rpc = PotholeActionRpc { container.backendClient.submitPotholeAction(it) },
            deviceTokenProvider = { container.deviceTokenStore.currentToken() },
            clientAppVersion = container.clientAppVersion,
            clientOSVersion = container.clientOSVersion,
            privacyZones = { container.privacyZones() },
        )

        val feedbackDrainer = FeedbackQueueDrainer(
            dao = db.feedbackDao(),
            submitter = FeedbackSubmitter { container.backendClient.submitFeedback(it) },
            clientAppVersion = container.clientAppVersion,
            platform = container.clientOSVersion,
        )

        val network = networkSnapshot()
        if (network.status == NetworkPathStatus.UNSATISFIED) return Result.retry()

        val readingOutcomes = readingCoordinator.drainAll(network)
        // Drain the action / feedback / photo queues regardless of the reading
        // outcome so a permanently-failed reading batch doesn't block other
        // queues.
        val potholeOutcomes = potholeCoordinator.drain()
        val feedbackOutcomes = feedbackDrainer.drain()

        // Photos stay off until the capture UI and the Data Safety answers
        // for photos exist (production config sets ENABLE_POTHOLE_PHOTOS=false).
        val photoOutcomes = if (container.config.enablePotholePhotos) {
            PotholePhotoCoordinator(
                dao = db.potholePhotoDao(),
                metadataRpc = PotholePhotoMetadataRpc { container.backendClient.beginPotholePhotoUpload(it) },
                bytesRpc = PotholePhotoBytesRpc { url, file -> container.backendClient.putPotholePhotoBytes(url, file) },
                deviceTokenProvider = { container.deviceTokenStore.currentToken() },
                clientAppVersion = container.clientAppVersion,
                clientOSVersion = container.clientOSVersion,
            ).drain()
        } else {
            emptyList()
        }

        val needsRetry = readingOutcomes.any {
            it is UploadDrainCoordinator.Outcome.BatchRetry || it is UploadDrainCoordinator.Outcome.Offline
        } ||
            potholeOutcomes.any { it is PotholeActionCoordinator.Outcome.Retry } ||
            feedbackOutcomes.any { it is FeedbackQueueDrainer.Outcome.Retry } ||
            photoOutcomes.any { it is PotholePhotoCoordinator.Outcome.Retry }

        return if (needsRetry) Result.retry() else Result.success()
    }

    private suspend fun pruneLocalData(container: RoadSenseContainer) {
        try {
            val pruned = container.retentionPruner.prune(Instant.now())
            if (pruned.total > 0) AppLog.info("pruned ${pruned.total} expired local rows")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Pruning failing must not block uploads; the next run retries.
            AppLog.error("local retention prune failed", e)
        }
    }

    private fun networkSnapshot(): NetworkPathSnapshot {
        val manager = applicationContext.getSystemService(ConnectivityManager::class.java)
            ?: return NetworkPathSnapshot(NetworkPathStatus.UNSATISFIED, isExpensive = false)
        val network = manager.activeNetwork
            ?: return NetworkPathSnapshot(NetworkPathStatus.UNSATISFIED, isExpensive = false)
        val capabilities = manager.getNetworkCapabilities(network)
            ?: return NetworkPathSnapshot(NetworkPathStatus.UNSATISFIED, isExpensive = false)
        val isConnected = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        return NetworkPathSnapshot(
            status = if (isConnected) NetworkPathStatus.SATISFIED else NetworkPathStatus.UNSATISFIED,
            isExpensive = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
        )
    }

    companion object {
        const val TAG = "upload-drain"
        const val PERIODIC_WORK_NAME = "upload-drain-periodic"

        /** Unique-work name for one-shot drains (drive end, "Upload now",
         *  feedback submit). Distinct from [PERIODIC_WORK_NAME]. */
        const val ONE_SHOT_WORK_NAME = "upload-drain-one-shot"

        /** Input flag: the user tapped "Upload now". */
        const val KEY_MANUAL = "manual"

        /**
         * Queues a one-shot drain. REPLACE, not KEEP: a request that was
         * enqueued earlier (for example during the drive, before the
         * session was sealed) may be sitting in WorkManager's own retry
         * backoff for many minutes; KEEP would silently drop the fresh
         * request behind it. A drain is idempotent (batches are claimed in a
         * transaction), so cancelling a running one is safe.
         */
        fun enqueueOneShot(context: Context, manual: Boolean) {
            val request = OneTimeWorkRequestBuilder<UploadDrainWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .setInputData(workDataOf(KEY_MANUAL to manual))
                .addTag(TAG)
                .build()
            try {
                WorkManager.getInstance(context).enqueueUniqueWork(
                    ONE_SHOT_WORK_NAME,
                    ExistingWorkPolicy.REPLACE,
                    request,
                )
            } catch (e: IllegalStateException) {
                // WorkManager isn't initialised in unit-test processes; the
                // periodic heartbeat still drains in production.
                AppLog.warn("could not queue a one-shot upload", e)
            }
        }
    }
}
