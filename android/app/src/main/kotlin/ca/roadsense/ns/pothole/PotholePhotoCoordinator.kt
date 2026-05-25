package ca.roadsense.ns.pothole

import ca.roadsense.ns.api.PotholePhotoBytesResult
import ca.roadsense.ns.api.PotholePhotoMetadataResult
import ca.roadsense.ns.api.PotholePhotoUploadRequest
import ca.roadsense.ns.api.UploadAttemptResult
import ca.roadsense.ns.api.UploadDisposition
import ca.roadsense.ns.api.UploadPolicy
import ca.roadsense.ns.data.room.PhotoUploadState
import ca.roadsense.ns.data.room.PotholePhotoDao
import ca.roadsense.ns.data.room.PotholePhotoEntity
import java.io.File
import java.time.Duration
import java.time.Instant

/**
 * Mirrors iOS' `PotholePhotoUploadCoordinator`. Drives the two-step photo
 * upload: POST metadata → `PUT` the JPEG bytes to the signed Supabase
 * Storage URL the server returned. State machine:
 *
 *   `pending_metadata`  → POST metadata
 *     → on signed URL: PUT bytes → `pending_moderation` (server-side review)
 *     → on 409 already_uploaded: `pending_moderation` (cleanup)
 *     → on 400 validation_failed: `failed_permanent`
 *     → on 429 / 5xx / network error: bump backoff, stay `pending_metadata`
 *
 * The bytes step never produces a permanent failure on its own — if the
 * signed URL expires (`upload_expires_at < now`) we re-issue from the
 * metadata endpoint per the contract in
 * `docs/implementation/03-api-contracts.md` → `POST /pothole-photos`.
 */
fun interface PotholePhotoMetadataRpc {
    suspend fun begin(request: PotholePhotoUploadRequest): PotholePhotoMetadataResult
}

fun interface PotholePhotoBytesRpc {
    suspend fun put(signedURL: String, file: File): PotholePhotoBytesResult
}

class PotholePhotoCoordinator(
    private val dao: PotholePhotoDao,
    private val metadataRpc: PotholePhotoMetadataRpc,
    private val bytesRpc: PotholePhotoBytesRpc,
    private val deviceTokenProvider: suspend () -> String,
    private val clientAppVersion: String,
    private val clientOSVersion: String,
    private val clock: () -> Instant = Instant::now,
) {
    sealed class Outcome {
        data class Succeeded(val photoId: java.util.UUID) : Outcome()
        data class Retry(val photoId: java.util.UUID, val nextAttemptAt: Instant) : Outcome()
        data class FailedPermanent(val photoId: java.util.UUID, val reason: String) : Outcome()
        data class FileMissing(val photoId: java.util.UUID) : Outcome()
    }

    suspend fun drain(limit: Int = 5): List<Outcome> {
        val now = clock()
        val pending = dao.pendingMetadata(PhotoUploadState.PENDING_METADATA.wireValue, now)
            .take(limit)
        return pending.map { processOne(it) }
    }

    private suspend fun processOne(photo: PotholePhotoEntity): Outcome {
        val file = File(photo.photoFilePath)
        if (!file.exists() || file.length() == 0L) {
            // The bytes are gone (user deleted the cache, retention pruned
            // the file, etc). Marking failed_permanent prevents an infinite
            // retry loop. The row stays in Room for the user's audit trail.
            dao.update(
                photo.copy(
                    uploadState = PhotoUploadState.FAILED_PERMANENT.wireValue,
                    lastAttemptAt = clock(),
                ),
            )
            return Outcome.FileMissing(photo.id)
        }

        val deviceToken = deviceTokenProvider()
        val payload = PotholePhotoUploadRequest(
            reportId = photo.id,
            segmentId = photo.segmentId,
            deviceToken = java.util.UUID.fromString(deviceToken),
            clientSentAt = clock(),
            clientAppVersion = clientAppVersion,
            clientOSVersion = clientOSVersion,
            lat = photo.latitude,
            lng = photo.longitude,
            accuracyM = photo.accuracyM,
            capturedAt = photo.capturedAt,
            contentType = "image/jpeg",
            byteSize = photo.byteSize,
            sha256 = photo.sha256Hex,
        )

        val attemptNumber = photo.uploadAttemptCount + 1
        val attemptedAt = clock()

        return when (val result = metadataRpc.begin(payload)) {
            is PotholePhotoMetadataResult.SignedURLIssued -> {
                // Step 2: PUT the bytes.
                when (val bytes = bytesRpc.put(result.uploadURL, file)) {
                    is PotholePhotoBytesResult.Accepted -> {
                        dao.update(
                            photo.copy(
                                uploadState = PhotoUploadState.PENDING_MODERATION.wireValue,
                                expectedObjectPath = result.expectedObjectPath,
                                uploadAttemptCount = attemptNumber,
                                lastAttemptAt = attemptedAt,
                                nextAttemptAt = null,
                                lastRequestId = result.requestId,
                            ),
                        )
                        Outcome.Succeeded(photo.id)
                    }
                    is PotholePhotoBytesResult.HttpError -> recordBytesRetry(
                        photo, attemptNumber, attemptedAt, statusCode = bytes.statusCode,
                    )
                    is PotholePhotoBytesResult.NetworkError -> recordBytesRetry(
                        photo, attemptNumber, attemptedAt, statusCode = null,
                    )
                }
            }

            is PotholePhotoMetadataResult.AlreadyUploaded -> {
                // Server already has the report — flip to pending_moderation
                // so the local row stops being scheduled, and let the user
                // see the same "uploaded" status they'd see on a fresh ack.
                dao.update(
                    photo.copy(
                        uploadState = PhotoUploadState.PENDING_MODERATION.wireValue,
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = attemptedAt,
                        nextAttemptAt = null,
                        lastRequestId = result.requestId,
                    ),
                )
                Outcome.Succeeded(photo.id)
            }

            is PotholePhotoMetadataResult.ValidationFailed -> {
                dao.update(
                    photo.copy(
                        uploadState = PhotoUploadState.FAILED_PERMANENT.wireValue,
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = attemptedAt,
                        lastRequestId = result.requestId,
                    ),
                )
                Outcome.FailedPermanent(photo.id, reason = result.message ?: "validation_failed")
            }

            is PotholePhotoMetadataResult.RateLimited -> recordRetry(
                photo,
                attemptNumber,
                attemptedAt,
                statusCode = 429,
                retryAfterSeconds = result.retryAfterSeconds,
                requestId = result.requestId,
            )

            is PotholePhotoMetadataResult.ServerError -> recordRetry(
                photo,
                attemptNumber,
                attemptedAt,
                statusCode = result.statusCode,
                retryAfterSeconds = null,
                requestId = result.requestId,
            )

            is PotholePhotoMetadataResult.NetworkError -> recordRetry(
                photo,
                attemptNumber,
                attemptedAt,
                statusCode = null,
                retryAfterSeconds = null,
                requestId = null,
            )
        }
    }

    private suspend fun recordRetry(
        photo: PotholePhotoEntity,
        attemptNumber: Int,
        attemptedAt: Instant,
        statusCode: Int?,
        retryAfterSeconds: Double?,
        requestId: String?,
    ): Outcome {
        val attemptResult = if (statusCode == null) {
            UploadAttemptResult.NetworkError
        } else {
            UploadAttemptResult.Http(statusCode, retryAfterSeconds)
        }
        return when (val disposition = UploadPolicy.evaluate(attemptResult, attemptNumber)) {
            is UploadDisposition.Retry -> {
                val nextAttempt = attemptedAt.plus(
                    Duration.ofMillis((disposition.afterSeconds * 1000).toLong()),
                )
                dao.update(
                    photo.copy(
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = attemptedAt,
                        nextAttemptAt = nextAttempt,
                        lastHttpStatusCode = statusCode,
                        lastRequestId = requestId,
                    ),
                )
                Outcome.Retry(photo.id, nextAttempt)
            }
            UploadDisposition.FailedPermanent -> {
                dao.update(
                    photo.copy(
                        uploadState = PhotoUploadState.FAILED_PERMANENT.wireValue,
                        uploadAttemptCount = attemptNumber,
                        lastAttemptAt = attemptedAt,
                        lastHttpStatusCode = statusCode,
                        lastRequestId = requestId,
                    ),
                )
                Outcome.FailedPermanent(
                    photoId = photo.id,
                    reason = statusCode?.let { "http_$it" } ?: "network",
                )
            }
            UploadDisposition.Succeeded -> error("retry path cannot succeed")
        }
    }

    private suspend fun recordBytesRetry(
        photo: PotholePhotoEntity,
        attemptNumber: Int,
        attemptedAt: Instant,
        statusCode: Int?,
    ): Outcome = recordRetry(
        photo = photo,
        attemptNumber = attemptNumber,
        attemptedAt = attemptedAt,
        statusCode = statusCode,
        retryAfterSeconds = null,
        requestId = null,
    )
}
