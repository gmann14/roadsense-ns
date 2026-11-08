package ca.roadsense.ns.upload

import androidx.room.RoomDatabase
import androidx.room.withTransaction
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
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.PrivacyZoneFilter
import kotlinx.coroutines.CancellationException
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
    private val database: RoomDatabase,
    private val readingDao: ReadingDao,
    private val batchDao: UploadBatchDao,
    private val uploadReadingsRpc: UploadReadingsRpc,
    private val deviceTokenProvider: suspend () -> String,
    private val clock: Clock = Clock.System,
    private val maxBatchSize: Int = MAX_READINGS_PER_BATCH,
    private val clientAppVersion: String = "unknown",
    private val clientOSVersion: String = "Android",
    /** Re-checked on every batch, fresh or retried: a zone added after a
     *  drive was sealed must still stop those readings from leaving. */
    private val privacyZones: suspend () -> List<PrivacyZone> = { emptyList() },
) {
    sealed class Outcome {
        data object NothingToDo : Outcome()
        data object Offline : Outcome()
        data class BatchSucceeded(val batchId: UUID, val accepted: Int, val rejected: Int) : Outcome()
        data class BatchRetry(val batchId: UUID, val nextAttemptAt: Instant) : Outcome()
        data class BatchFailedPermanent(val batchId: UUID, val httpStatus: Int?) : Outcome()

        /** Every reading in the batch fell inside a privacy zone; nothing sent. */
        data class BatchEmptiedByPrivacyZone(val batchId: UUID) : Outcome()
    }

    interface Clock {
        fun now(): Instant
        object System : Clock {
            override fun now(): Instant = Instant.now()
        }
    }

    /**
     * Drains batches until there is nothing left, a batch needs a retry, the
     * network drops, or [maxBatches] / [timeBudget] runs out. A long drive
     * produces thousands of readings; one 500-reading batch per 15-minute
     * heartbeat would take hours. Bounded so one worker run stays well inside
     * WorkManager's 10-minute execution window.
     */
    suspend fun drainAll(
        network: NetworkPathSnapshot,
        maxBatches: Int = MAX_BATCHES_PER_RUN,
        timeBudget: Duration = DRAIN_TIME_BUDGET,
    ): List<Outcome> {
        val outcomes = mutableListOf<Outcome>()
        val deadline = clock.now().plus(timeBudget)
        while (outcomes.size < maxBatches && !clock.now().isAfter(deadline)) {
            val outcome = drainOnce(network)
            outcomes += outcome
            val keepGoing = outcome is Outcome.BatchSucceeded ||
                outcome is Outcome.BatchFailedPermanent ||
                outcome is Outcome.BatchEmptiedByPrivacyZone
            if (!keepGoing) break
        }
        return outcomes
    }

    suspend fun drainOnce(network: NetworkPathSnapshot): Outcome {
        if (network.status == NetworkPathStatus.UNSATISFIED) {
            return Outcome.Offline
        }

        // Reclaim batches stranded IN_FLIGHT by a prior worker cancellation,
        // process death, or an exception that wasn't caught below (before
        // this fix, only IOException was handled — anything else left the
        // row IN_FLIGHT forever since `nextDrainable` only ever queries
        // PENDING). Age-gated so we don't race an upload that's still
        // genuinely in progress in another coroutine.
        batchDao.reclaimStaleInFlight(
            inFlightState = UploadBatchState.IN_FLIGHT,
            pendingState = UploadBatchState.PENDING,
            cutoff = clock.now().minus(STALE_IN_FLIGHT_THRESHOLD),
        )

        // The select-then-insert-then-assign sequence must be atomic: without
        // a transaction, two concurrent drain workers can both select the
        // same pending readings before either assigns them to a batch,
        // producing two batches (and a double upload) for the same rows.
        // Wrapping it in a Room transaction serializes the critical section.
        val (batchId, assigned) = database.withTransaction {
            val dueBatch = batchDao.nextDrainable(UploadBatchState.PENDING, clock.now(), limit = 1).firstOrNull()

            if (dueBatch != null) {
                val existingReadings = readingDao.byBatch(dueBatch.id)
                dueBatch.id to existingReadings
            } else {
                val pendingCount = readingDao.readyForUploadCount()
                if (!UploadEligibilityPolicy.shouldUpload(pendingCount, network, now = clock.now())) {
                    return@withTransaction null
                }

                val pending = readingDao.pendingForUpload(limit = maxBatchSize)
                if (pending.isEmpty()) return@withTransaction null

                val newBatchId = UUID.randomUUID()
                batchDao.insert(
                    UploadBatchEntity(
                        id = newBatchId,
                        state = UploadBatchState.PENDING,
                        createdAt = clock.now(),
                        attemptCount = 0,
                        readingCount = pending.size,
                    )
                )
                readingDao.assignBatch(pending.map { it.id }, newBatchId)
                newBatchId to pending
            }
        } ?: return Outcome.NothingToDo

        if (assigned.isEmpty()) {
            batchDao.markAttempt(batchId, UploadBatchState.FAILED_PERMANENT, clock.now())
            return Outcome.BatchFailedPermanent(batchId, null)
        }

        val zones = privacyZones()
        val inZone = assigned.filter { PrivacyZoneFilter.isInside(it.latitude, it.longitude, zones) }
        if (inZone.isNotEmpty()) {
            readingDao.markDroppedByPrivacyZone(inZone.map { it.id })
        }
        val inZoneIds = inZone.map { it.id }.toSet()
        val readings = assigned.filterNot { it.id in inZoneIds }
        if (readings.isEmpty()) {
            batchDao.markAttempt(batchId, UploadBatchState.FAILED_PERMANENT, clock.now())
            return Outcome.BatchEmptiedByPrivacyZone(batchId)
        }

        val token = deviceTokenProvider()
        val request = UploadReadingsRequest(
            batchId = batchId,
            deviceToken = token,
            clientSentAt = clock.now(),
            clientAppVersion = clientAppVersion,
            clientOSVersion = clientOSVersion,
            readings = readings.map { it.toPayload() },
        )

        batchDao.markAttempt(batchId, UploadBatchState.IN_FLIGHT, clock.now())

        val response: Response<UploadReadingsResponse> = try {
            uploadReadingsRpc.upload(request)
        } catch (e: CancellationException) {
            // Never swallow cancellation — rethrow so structured concurrency
            // still works. The batch is left IN_FLIGHT; `reclaimStaleInFlight`
            // at the top of the next `drainOnce` call resets it to PENDING
            // once it's old enough to safely assume the cancelled attempt
            // isn't still in flight.
            throw e
        } catch (e: IOException) {
            val attemptNumber = batchDao.findById(batchId)?.attemptCount ?: 1
            return handleNetworkFailure(batchId, attemptNumber = attemptNumber)
        } catch (e: Exception) {
            // Non-IO failures (serialization errors, unexpected runtime
            // exceptions, etc.) used to propagate uncaught, leaving the batch
            // stuck IN_FLIGHT forever since nothing else ever retried it.
            // Treat them the same as a network failure: retry with backoff.
            val attemptNumber = batchDao.findById(batchId)?.attemptCount ?: 1
            return handleNetworkFailure(batchId, attemptNumber = attemptNumber)
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
                val batch = batchDao.findById(batchId) ?: return Outcome.NothingToDo
                batchDao.update(
                    batch.copy(
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
                val batch = batchDao.findById(batchId) ?: return Outcome.NothingToDo
                batchDao.update(
                    batch.copy(
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

    companion object {
        /** How long a batch can sit IN_FLIGHT before we assume the attempt
         *  that set it there is gone (cancelled worker, dead process, etc.)
         *  and it's safe to reclaim back to PENDING. */
        val STALE_IN_FLIGHT_THRESHOLD: Duration = Duration.ofMinutes(5)

        /** iOS parity (`UploadQueue.maxReadingsPerBatch`). The server accepts
         *  up to 1,000 readings and a 256 KiB body; 500 keeps a batch well
         *  under both, so a 413 is not expected (it is retried, not dropped,
         *  if a proxy ever sends one — see `UploadPolicy`). */
        const val MAX_READINGS_PER_BATCH: Int = 500

        /** Upper bound on batches per worker run (`drainAll`). */
        const val MAX_BATCHES_PER_RUN: Int = 20

        /** Upper bound on wall time per worker run (`drainAll`). */
        val DRAIN_TIME_BUDGET: Duration = Duration.ofMinutes(5)
    }
}
