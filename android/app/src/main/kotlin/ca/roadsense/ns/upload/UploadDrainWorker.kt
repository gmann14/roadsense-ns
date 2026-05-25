package ca.roadsense.ns.upload

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.api.NetworkPathSnapshot
import ca.roadsense.ns.api.NetworkPathStatus
import ca.roadsense.ns.feedback.FeedbackQueueDrainer
import ca.roadsense.ns.feedback.FeedbackSubmitter
import ca.roadsense.ns.pothole.PotholeActionCoordinator
import ca.roadsense.ns.pothole.PotholeActionRpc
import ca.roadsense.ns.pothole.PotholePhotoBytesRpc
import ca.roadsense.ns.pothole.PotholePhotoCoordinator
import ca.roadsense.ns.pothole.PotholePhotoMetadataRpc

/**
 * WorkManager entry point for the unified upload drain — readings, pothole
 * actions, and feedback all run from this single worker so the network
 * doesn't get hit by three concurrent workers fighting for the same row.
 */
class UploadDrainWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = RoadSenseContainer.from(applicationContext)

        val readingCoordinator = UploadDrainCoordinator(
            readingDao = container.database.readingDao(),
            batchDao = container.database.uploadBatchDao(),
            uploadReadingsRpc = UploadReadingsRpc { request ->
                container.backendClient.uploadReadings(request)
            },
            deviceTokenProvider = { container.deviceTokenStore.currentToken() },
        )

        // Promote any pothole rows whose undo windows have elapsed before
        // the network drain runs. Mirrors iOS' coordinator that calls
        // `promoteExpiredUndos` on the same heartbeat.
        container.potholeActions.promoteExpiredUndos()

        val potholeCoordinator = PotholeActionCoordinator(
            dao = container.database.potholeActionDao(),
            rpc = PotholeActionRpc { container.backendClient.submitPotholeAction(it) },
            deviceTokenProvider = { container.deviceTokenStore.currentToken() },
            clientAppVersion = container.clientAppVersion,
            clientOSVersion = container.clientOSVersion,
        )

        val feedbackDrainer = FeedbackQueueDrainer(
            dao = container.database.feedbackDao(),
            submitter = FeedbackSubmitter { container.backendClient.submitFeedback(it) },
            clientAppVersion = container.clientAppVersion,
            platform = container.clientOSVersion,
        )

        // Pothole photo drain — only meaningful once the CameraX capture UI
        // populates pending_metadata rows. The coordinator is wired now so
        // that as soon as a photo lands in Room, the next heartbeat picks
        // it up; until then `drain()` is a no-op.
        val photoCoordinator = PotholePhotoCoordinator(
            dao = container.database.potholePhotoDao(),
            metadataRpc = PotholePhotoMetadataRpc { container.backendClient.beginPotholePhotoUpload(it) },
            bytesRpc = PotholePhotoBytesRpc { url, file -> container.backendClient.putPotholePhotoBytes(url, file) },
            deviceTokenProvider = { container.deviceTokenStore.currentToken() },
            clientAppVersion = container.clientAppVersion,
            clientOSVersion = container.clientOSVersion,
        )

        val network = networkSnapshot()
        if (network.status == NetworkPathStatus.UNSATISFIED) return Result.retry()

        val readingOutcome = readingCoordinator.drainOnce(network)
        // Drain the action / feedback / photo queues regardless of the reading
        // outcome so a permanently-failed reading batch doesn't block other
        // queues.
        val potholeOutcomes = potholeCoordinator.drain()
        val feedbackOutcomes = feedbackDrainer.drain()
        val photoOutcomes = photoCoordinator.drain()

        val needsRetry = readingOutcome is UploadDrainCoordinator.Outcome.BatchRetry ||
            readingOutcome is UploadDrainCoordinator.Outcome.Offline ||
            potholeOutcomes.any { it is PotholeActionCoordinator.Outcome.Retry } ||
            feedbackOutcomes.any { it is FeedbackQueueDrainer.Outcome.Retry } ||
            photoOutcomes.any { it is PotholePhotoCoordinator.Outcome.Retry }

        return if (needsRetry) Result.retry() else Result.success()
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
    }
}
