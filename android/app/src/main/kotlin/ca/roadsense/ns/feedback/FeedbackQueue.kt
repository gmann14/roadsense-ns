package ca.roadsense.ns.feedback

import ca.roadsense.ns.api.FeedbackSubmissionPayload
import ca.roadsense.ns.api.FeedbackSubmissionResult
import ca.roadsense.ns.data.room.FeedbackDao
import ca.roadsense.ns.data.room.FeedbackEntity
import ca.roadsense.ns.data.room.FeedbackUploadState
import kotlinx.coroutines.flow.Flow
import java.time.Duration
import java.time.Instant
import java.util.UUID

/**
 * Mirror of iOS `FeedbackQueue`. Persists feedback locally so it survives
 * process death, drains when the app foregrounds and on the periodic
 * upload-drain heartbeat.
 */
class FeedbackQueue(
    private val dao: FeedbackDao,
    private val clock: () -> Instant = { Instant.now() },
) {
    suspend fun enqueue(
        source: String,
        category: String,
        message: String,
        replyEmail: String?,
        contactConsent: Boolean,
        locale: String?,
        route: String?,
    ): UUID {
        val now = clock()
        val entry = FeedbackEntity(
            id = UUID.randomUUID(),
            source = source,
            category = category,
            message = message,
            replyEmail = replyEmail,
            contactConsent = contactConsent,
            locale = locale,
            route = route,
            createdAt = now,
        )
        dao.insert(entry)
        return entry.id
    }

    suspend fun pendingCount(): Int = dao.pendingCount(FeedbackUploadState.PENDING.wireValue)

    fun observePendingCount(): Flow<Int> =
        dao.observePendingCount(FeedbackUploadState.PENDING.wireValue)

    suspend fun pending(): List<FeedbackEntity> =
        dao.pending(FeedbackUploadState.PENDING.wireValue, clock())

    suspend fun delete(id: UUID): Boolean = dao.delete(id) > 0
}

/**
 * Submitter contract: the queue drainer doesn't depend on the full
 * `BackendClient`; this lets tests stub network behavior without spinning up
 * MockWebServer.
 */
fun interface FeedbackSubmitter {
    suspend fun submit(payload: FeedbackSubmissionPayload): FeedbackSubmissionResult
}

/**
 * Pure coordinator that drains the feedback queue. Mirrors iOS
 * `FeedbackQueueDrainer`.
 *
 * Returns a list of per-entry outcomes so the caller can decide whether to
 * reschedule. WorkManager workers translate the list into a single
 * Result.success/retry.
 */
class FeedbackQueueDrainer(
    private val dao: FeedbackDao,
    private val submitter: FeedbackSubmitter,
    private val clientAppVersion: String,
    private val platform: String,
    private val clock: () -> Instant = { Instant.now() },
) {
    sealed class Outcome {
        data object NothingToDo : Outcome()
        data class Submitted(val entryId: UUID, val serverId: String) : Outcome()
        data class ValidationFailed(val entryId: UUID, val fieldErrors: Map<String, String>) : Outcome()
        data class Retry(val entryId: UUID, val nextAttemptAt: Instant) : Outcome()
        data class FailedPermanent(val entryId: UUID) : Outcome()
    }

    suspend fun drain(): List<Outcome> {
        val now = clock()
        val due = dao.pending(FeedbackUploadState.PENDING.wireValue, now)
        if (due.isEmpty()) return listOf(Outcome.NothingToDo)
        return due.map { drainOne(it) }
    }

    private suspend fun drainOne(entry: FeedbackEntity): Outcome {
        val payload = FeedbackSubmissionPayload(
            source = entry.source,
            category = entry.category,
            message = entry.message,
            replyEmail = entry.replyEmail,
            contactConsent = entry.contactConsent,
            appVersion = clientAppVersion,
            platform = platform,
            locale = entry.locale,
            route = entry.route,
        )

        val now = clock()
        val attempt = entry.uploadAttemptCount + 1
        return when (val result = submitter.submit(payload)) {
            is FeedbackSubmissionResult.Accepted -> {
                dao.update(
                    entry.copy(
                        uploadState = FeedbackUploadState.SUBMITTED.wireValue,
                        uploadAttemptCount = attempt,
                        lastAttemptAt = now,
                        nextAttemptAt = null,
                        lastRequestId = result.requestId,
                        lastFieldErrors = null,
                    )
                )
                Outcome.Submitted(entry.id, result.id)
            }

            is FeedbackSubmissionResult.ValidationFailed -> {
                // Validation errors are permanent — the user has to edit and
                // resubmit. We stop retrying so the queue doesn't loop.
                dao.update(
                    entry.copy(
                        uploadState = FeedbackUploadState.FAILED_PERMANENT.wireValue,
                        uploadAttemptCount = attempt,
                        lastAttemptAt = now,
                        lastRequestId = result.requestId,
                        lastFieldErrors = result.fieldErrors.entries.joinToString(",") {
                            "${it.key}=${it.value}"
                        },
                    )
                )
                Outcome.ValidationFailed(entry.id, result.fieldErrors)
            }

            is FeedbackSubmissionResult.RateLimited -> {
                val nextAttemptAt = now.plus(
                    Duration.ofSeconds(((result.retryAfterSeconds ?: 60.0).toLong())),
                )
                dao.update(
                    entry.copy(
                        uploadAttemptCount = attempt,
                        lastAttemptAt = now,
                        nextAttemptAt = nextAttemptAt,
                        lastRequestId = result.requestId,
                    )
                )
                Outcome.Retry(entry.id, nextAttemptAt)
            }

            is FeedbackSubmissionResult.ServerError, is FeedbackSubmissionResult.NetworkError -> {
                val backoffSeconds = (1 shl minOf(attempt - 1, 6)).toLong().coerceAtLeast(1)
                val nextAttemptAt = now.plus(Duration.ofSeconds(backoffSeconds))
                if (attempt > 5) {
                    dao.update(
                        entry.copy(
                            uploadState = FeedbackUploadState.FAILED_PERMANENT.wireValue,
                            uploadAttemptCount = attempt,
                            lastAttemptAt = now,
                            nextAttemptAt = null,
                            lastRequestId = (result as? FeedbackSubmissionResult.ServerError)?.requestId,
                        )
                    )
                    Outcome.FailedPermanent(entry.id)
                } else {
                    dao.update(
                        entry.copy(
                            uploadAttemptCount = attempt,
                            lastAttemptAt = now,
                            nextAttemptAt = nextAttemptAt,
                            lastRequestId = (result as? FeedbackSubmissionResult.ServerError)?.requestId,
                        )
                    )
                    Outcome.Retry(entry.id, nextAttemptAt)
                }
            }
        }
    }
}
