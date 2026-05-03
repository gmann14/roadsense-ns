package ca.roadsense.ns.upload

import ca.roadsense.ns.api.NetworkPathSnapshot
import ca.roadsense.ns.api.NetworkPathStatus
import ca.roadsense.ns.api.UploadAttemptResult
import ca.roadsense.ns.api.UploadCodec
import ca.roadsense.ns.api.UploadDisposition
import ca.roadsense.ns.api.UploadEligibilityPolicy
import ca.roadsense.ns.api.UploadErrorEnvelope
import ca.roadsense.ns.api.UploadPolicy
import ca.roadsense.ns.api.UploadReadingPayload
import ca.roadsense.ns.api.UploadReadingsRequest
import ca.roadsense.ns.api.UploadReadingsResponse
import ca.roadsense.ns.data.room.ReadingDao
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.UploadBatchDao
import ca.roadsense.ns.data.room.UploadBatchEntity
import ca.roadsense.ns.data.room.UploadBatchState
import retrofit2.Response
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.util.UUID

/**
 * Pure-coordinator that drives one upload-drain pass: pull pending readings
 * → assign a batch → POST → mark uploaded or schedule retry. Mirrors iOS
 * `UploadDrainCoordinator`. Returns a result enum so the caller (the
 * WorkManager worker, eventually a foreground-end hook) decides whether to
 * reschedule.
 *
 * Testable on Robolectric with an in-memory Room DB and a stubbed
 * `BackendClient`-like callable.
 */
/**
 * Minimal upload contract the coordinator depends on. The real
 * `BackendClient` implements this; tests stub it without standing up
 * MockWebServer.
 */
fun interface UploadReadingsRpc {
    suspend fun upload(request: UploadReadingsRequest): Response<UploadReadingsResponse>
}

class UploadDrainCoordinator(
    private val readingDao: ReadingDao,
    private val batchDao: UploadBatchDao,
    private val uploadReadingsRpc: UploadReadingsRpc,
    private val deviceTokenProvider: suspend () -> String,
    private val clock: Clock = Clock.System,
    private val maxBatchSize: Int = 200,
) {
    sealed class Outcome {
        data object NothingToDo : Outcome()
        data object Offline : Outcome()
        data class BatchSucceeded(val batchId: UUID, val accepted: Int, val rejected: Int) : Outcome()
        data class BatchRetry(val batchId: UUID, val nextAttemptAt: Instant) : Outcome()
        data class BatchFailedPermanent(val batchId: UUID, val httpStatus: Int?) : Outcome()
    }

    interface Clock {
        fun now(): Instant
        object System : Clock {
            override fun now(): Instant = Instant.now()
        }
    }

    suspend fun drainOnce(network: NetworkPathSnapshot): Outcome {
        val pendingCount = readingDao.pendingCount()
        if (!UploadEligibilityPolicy.shouldUpload(pendingCount, network, now = clock.now())) {
            return when (network.status) {
                NetworkPathStatus.UNSATISFIED -> Outcome.Offline
                NetworkPathStatus.SATISFIED -> Outcome.NothingToDo
            }
        }

        val readings = readingDao.pendingForUpload(limit = maxBatchSize)
        if (readings.isEmpty()) return Outcome.NothingToDo

        val batchId = UUID.randomUUID()
        batchDao.insert(
            UploadBatchEntity(
                id = batchId,
                state = UploadBatchState.PENDING,
                createdAt = clock.now(),
                attemptCount = 0,
                readingCount = readings.size,
            )
        )
        readingDao.assignBatch(readings.map { it.id }, batchId)

        val token = deviceTokenProvider()
        val request = UploadReadingsRequest(
            batchId = batchId,
            deviceToken = token,
            clientSentAt = clock.now(),
            clientAppVersion = "Android 0.1.0",
            clientOSVersion = "Android ${android.os.Build.VERSION.RELEASE}",
            readings = readings.map { it.toPayload() },
        )

        batchDao.markAttempt(batchId, UploadBatchState.IN_FLIGHT, clock.now())

        val response: Response<UploadReadingsResponse> = try {
            uploadReadingsRpc.upload(request)
        } catch (e: IOException) {
            return handleNetworkFailure(batchId, attemptNumber = 1)
        }

        return handleResponse(batchId, response)
    }

    private suspend fun handleResponse(
        batchId: UUID,
        response: Response<UploadReadingsResponse>,
    ): Outcome {
        val attemptNumber = batchDao.findById(batchId)?.attemptCount ?: 1
        val retryAfter = response.headers()["Retry-After"]?.toDoubleOrNull()
        val attemptResult = UploadAttemptResult.Http(response.code(), retryAfter)

        return when (val disposition = UploadPolicy.evaluate(attemptResult, attemptNumber)) {
            UploadDisposition.Succeeded -> {
                val body = response.body()
                readingDao.markBatchUploaded(batchId, clock.now())
                batchDao.markAttempt(batchId, UploadBatchState.SUCCEEDED, clock.now())
                Outcome.BatchSucceeded(
                    batchId = batchId,
                    accepted = body?.accepted ?: 0,
                    rejected = body?.rejected ?: 0,
                )
            }

            is UploadDisposition.Retry -> {
                val nextAttemptAt = clock.now().plus(
                    Duration.ofMillis((disposition.afterSeconds * 1000).toLong())
                )
                readingDao.releaseBatch(batchId)
                batchDao.update(
                    batchDao.findById(batchId)!!.copy(
                        state = UploadBatchState.PENDING,
                        nextAttemptAt = nextAttemptAt,
                        lastHttpStatusCode = response.code(),
                    )
                )
                Outcome.BatchRetry(batchId, nextAttemptAt)
            }

            UploadDisposition.FailedPermanent -> {
                batchDao.markAttempt(batchId, UploadBatchState.FAILED_PERMANENT, clock.now())
                Outcome.BatchFailedPermanent(batchId, response.code())
            }
        }
    }

    private suspend fun handleNetworkFailure(batchId: UUID, attemptNumber: Int): Outcome {
        return when (val disposition = UploadPolicy.evaluate(UploadAttemptResult.NetworkError, attemptNumber)) {
            is UploadDisposition.Retry -> {
                val nextAttemptAt = clock.now().plus(
                    Duration.ofMillis((disposition.afterSeconds * 1000).toLong())
                )
                readingDao.releaseBatch(batchId)
                batchDao.update(
                    batchDao.findById(batchId)!!.copy(
                        state = UploadBatchState.PENDING,
                        nextAttemptAt = nextAttemptAt,
                    )
                )
                Outcome.BatchRetry(batchId, nextAttemptAt)
            }

            UploadDisposition.FailedPermanent -> {
                batchDao.markAttempt(batchId, UploadBatchState.FAILED_PERMANENT, clock.now())
                Outcome.BatchFailedPermanent(batchId, null)
            }

            UploadDisposition.Succeeded -> error("network failure cannot succeed")
        }
    }

    private fun ReadingEntity.toPayload(): UploadReadingPayload = UploadReadingPayload(
        lat = latitude,
        lng = longitude,
        roughnessRms = roughnessRMS,
        speedKmh = speedKMH,
        heading = heading,
        gpsAccuracyM = gpsAccuracyM,
        isPothole = isPothole,
        potholeMagnitude = potholeMagnitude,
        recordedAt = recordedAt,
    )

    /** Convenience for tests that want to read an error envelope from a 4xx body. */
    fun parseErrorEnvelope(body: String): UploadErrorEnvelope =
        UploadCodec.json.decodeFromString(UploadErrorEnvelope.serializer(), body)
}
