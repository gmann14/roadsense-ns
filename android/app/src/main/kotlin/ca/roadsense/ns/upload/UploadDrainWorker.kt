package ca.roadsense.ns.upload

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

/**
 * WorkManager entry point for upload drain. Wired up alongside Hilt /
 * service-locator in A12-4; for now the worker exists as a hook so the
 * manifest declaration and constraints can be tested.
 */
class UploadDrainWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        // A12-4 follow-on: instantiate UploadDrainCoordinator from the
        // service-locator container, call drainOnce, translate the Outcome
        // to Result.success / Result.retry / Result.failure.
        return Result.success()
    }
}
