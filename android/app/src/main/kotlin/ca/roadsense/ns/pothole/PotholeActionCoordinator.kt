package ca.roadsense.ns.pothole

import ca.roadsense.ns.api.PotholeActionUploadRequest
import ca.roadsense.ns.api.PotholeActionUploadResponse
import ca.roadsense.ns.api.UploadAttemptResult
import ca.roadsense.ns.api.UploadDisposition
import ca.roadsense.ns.api.UploadPolicy
import ca.roadsense.ns.data.room.PotholeActionDao
import ca.roadsense.ns.data.room.PotholeActionEntity
import ca.roadsense.ns.data.room.PotholeActionType
import ca.roadsense.ns.data.room.PotholeActionUploadState
import retrofit2.Response
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.util.UUID

/**
 * Network entry point for `pothole-actions`. Mirrors iOS
 * `APIClient.submitPotholeAction`. Wrapped behind an interface so tests can
 * stub it without standing up MockWebServer.
 */
fun interface PotholeActionRpc {
    suspend fun submit(request: PotholeActionUploadRequest): Response<PotholeActionUploadResponse>
}

/**
 * Mirrors iOS `PotholeActionUploader`: pulls actions whose undo window has
 * elapsed and whose backoff window has elapsed, posts them, and updates the
 * row to PENDING_UNDO/PENDING_UPLOAD/FAILED_PERMANENT according to the
 * shared `UploadPolicy`.
 *
 * The coordinator does not enqueue WorkManager jobs itself — it is called
 * from `UploadDrainWorker` and from one-shot drive-end hooks.
 */
class PotholeActionCoordinator(
    private val dao: PotholeActionDao,
    private val rpc: PotholeActionRpc,
    private val deviceTokenProvider: suspend () -> String,
    private val clientAppVersion: String,
    private val clientOSVersion: String,
    private val clock: () -> Instant = { Instant.now() },
) {
    sealed class Outcome {
        data object NothingToDo : Outcome()
        data class Submitted(val actionId: UUID, val potholeReportId: UUID) : Outcome()
        data class Retry(val actionId: UUID, val nextAttemptAt: Instant) : Outcome()
        data class FailedPermanent(val actionId: UUID, val httpStatus: Int?) : Outcome()
    }

    /** Drains as many due actions as possible in one call. Returns each per-action outcome. */
    suspend fun drain(): List<Outcome> {
        val now = clock()
        val due = dao.pendingForUpload(
            pendingUpload = PotholeActionUploadState.PENDING_UPLOAD.wireValue,
            now = now,
        )
        if (due.isEmpty()) return listOf(Outcome.NothingToDo)
        return due.map { submit(it) }
    }

    /** Submits a single action and updates its row. */
    suspend fun submit(action: PotholeActionEntity): Outcome {
        val now = clock()
        val token = deviceTokenProvider()
        val request = PotholeActionUploadRequest(
            actionId = action.id,
            deviceToken = token,
            clientSentAt = now,
            clientAppVersion = clientAppVersion,
            clientOSVersion = clientOSVersion,
            actionType = action.actionType,
            potholeReportId = action.potholeReportId,
            lat = action.latitude,
            lng = action.longitude,
            accuracyM = action.accuracyM,
            recordedAt = action.recordedAt,
            sensorBackedMagnitudeG = action.sensorBackedMagnitudeG,
            sensorBackedAt = action.sensorBackedAt,
        )

        val response: Response<PotholeActionUploadResponse> = try {
            rpc.submit(request)
        } catch (e: IOException) {
            return handleNetworkFailure(action, attempt = action.uploadAttemptCount + 1)
        }

        val attemptNumber = action.uploadAttemptCount + 1
        val retryAfter = response.headers()["Retry-After"]?.toDoubleOrNull()
        val attemptResult = UploadAttemptResult.Http(response.code(), retryAfter)

        return when (val disposition = UploadPolicy.evaluate(attemptResult, attemptNumber)) {
            UploadDisposition.Succeeded -> {
                val body = response.body()
                val reportId = body?.potholeReportId ?: action.potholeReportId ?: action.id
                dao.update(
                    action.copy(
                        potholeReportId = reportId,
                        uploadState = PotholeActionUploadState.SUBMITTED.wireValue,
                        uploadedAt = now,
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = now,
                        nextAttemptAt = null,
                        lastHttpStatusCode = response.code(),
                    )
                )
                Outcome.Submitted(action.id, reportId)
            }
            is UploadDisposition.Retry -> {
                val nextAttemptAt = clock().plus(
                    Duration.ofMillis((disposition.afterSeconds * 1000).toLong())
                )
                dao.update(
                    action.copy(
                        uploadState = PotholeActionUploadState.PENDING_UPLOAD.wireValue,
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = clock(),
                        nextAttemptAt = nextAttemptAt,
                        lastHttpStatusCode = response.code(),
                    )
                )
                Outcome.Retry(action.id, nextAttemptAt)
            }
            UploadDisposition.FailedPermanent -> {
                dao.update(
                    action.copy(
                        uploadState = PotholeActionUploadState.FAILED_PERMANENT.wireValue,
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = clock(),
                        lastHttpStatusCode = response.code(),
                    )
                )
                Outcome.FailedPermanent(action.id, response.code())
            }
        }
    }

    private suspend fun handleNetworkFailure(action: PotholeActionEntity, attempt: Int): Outcome {
        return when (val disposition = UploadPolicy.evaluate(UploadAttemptResult.NetworkError, attempt)) {
            is UploadDisposition.Retry -> {
                val nextAttemptAt = clock().plus(
                    Duration.ofMillis((disposition.afterSeconds * 1000).toLong())
                )
                dao.update(
                    action.copy(
                        uploadAttemptCount = attempt,
                        lastAttemptAt = clock(),
                        nextAttemptAt = nextAttemptAt,
                    )
                )
                Outcome.Retry(action.id, nextAttemptAt)
            }
            UploadDisposition.FailedPermanent -> {
                dao.update(
                    action.copy(
                        uploadState = PotholeActionUploadState.FAILED_PERMANENT.wireValue,
                        uploadAttemptCount = attempt,
                        lastAttemptAt = clock(),
                    )
                )
                Outcome.FailedPermanent(action.id, null)
            }
            UploadDisposition.Succeeded -> error("network failure cannot succeed")
        }
    }

    companion object {
        /** Default undo window the iOS UI uses before flipping PENDING_UNDO → PENDING_UPLOAD. */
        val UNDO_WINDOW: Duration = Duration.ofSeconds(8)

        /** Builds a manual_report row in PENDING_UNDO. The UI flips it to
         *  PENDING_UPLOAD when the undo window expires (or to deletion if the
         *  user taps "Undo"). */
        fun manualReport(
            location: PotholeLocation,
            now: Instant = Instant.now(),
            sensorBackedMagnitudeG: Double? = null,
            sensorBackedAt: Instant? = null,
        ): PotholeActionEntity = PotholeActionEntity(
            id = UUID.randomUUID(),
            potholeReportId = null,
            actionType = PotholeActionType.MANUAL_REPORT.wireValue,
            latitude = location.latitude,
            longitude = location.longitude,
            accuracyM = location.accuracyM,
            recordedAt = now,
            createdAt = now,
            undoExpiresAt = now.plus(UNDO_WINDOW),
            uploadState = PotholeActionUploadState.PENDING_UNDO.wireValue,
            sensorBackedMagnitudeG = sensorBackedMagnitudeG,
            sensorBackedAt = sensorBackedAt,
        )
    }
}

data class PotholeLocation(
    val latitude: Double,
    val longitude: Double,
    val accuracyM: Double,
)
