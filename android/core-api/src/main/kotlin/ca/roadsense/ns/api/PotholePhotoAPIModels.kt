package ca.roadsense.ns.api

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Wire-format mirror of iOS `PotholePhotoUploadRequest` (see
 * `ios/Sources/RoadSenseNSBootstrap/Network/UploadAPIModels.swift`).
 *
 * The JSON shape is locked by [PotholePhotoUploadRequestJsonTest] — drift
 * here would silently break the `pothole-photos` Edge Function that already
 * speaks iOS. Backend contract lives in `docs/implementation/03-api-contracts.md`
 * → `POST /pothole-photos`.
 */
@Serializable
data class PotholePhotoUploadRequest(
    @SerialName("report_id")
    @Serializable(with = UuidLowercaseSerializer::class)
    val reportId: UUID,
    @SerialName("segment_id")
    @Serializable(with = UuidLowercaseSerializer::class)
    val segmentId: UUID? = null,
    @SerialName("device_token")
    @Serializable(with = UuidLowercaseSerializer::class)
    val deviceToken: UUID,
    @SerialName("client_sent_at")
    @Serializable(with = InstantIso8601Serializer::class)
    val clientSentAt: Instant,
    @SerialName("client_app_version") val clientAppVersion: String,
    @SerialName("client_os_version") val clientOSVersion: String,
    @SerialName("lat") val lat: Double,
    @SerialName("lng") val lng: Double,
    @SerialName("accuracy_m") val accuracyM: Double,
    @SerialName("captured_at")
    @Serializable(with = InstantIso8601Serializer::class)
    val capturedAt: Instant,
    @SerialName("content_type") val contentType: String,
    @SerialName("byte_size") val byteSize: Long,
    @SerialName("sha256") val sha256: String,
)

/**
 * Success response — a short-lived signed-upload URL the client `PUT`s the
 * photo bytes to. Mirrors iOS `PotholePhotoUploadResponse`.
 */
@Serializable
data class PotholePhotoUploadResponse(
    @SerialName("report_id")
    @Serializable(with = UuidLowercaseSerializer::class)
    val reportId: UUID,
    @SerialName("upload_url") val uploadURL: String,
    @SerialName("upload_expires_at")
    @Serializable(with = InstantIso8601Serializer::class)
    val uploadExpiresAt: Instant,
    @SerialName("expected_object_path") val expectedObjectPath: String,
)

/** 409 response when the same `report_id` was already submitted. Client
 *  treats this as success (the server already has the report). */
@Serializable
data class PotholePhotoAlreadyUploadedResponse(
    @SerialName("error") val error: String,
    @SerialName("message") val message: String? = null,
    @SerialName("request_id") val requestId: String? = null,
)

/**
 * Discriminated result that hides HTTP status codes from callers. Mirrors
 * iOS' `PotholePhotoUploadResult` and the existing
 * `FeedbackSubmissionResult` / `PotholeActionResult` patterns.
 */
sealed class PotholePhotoMetadataResult {
    /** Server returned a signed URL the client should now `PUT` the bytes to. */
    data class SignedURLIssued(
        val reportId: UUID,
        val uploadURL: String,
        val uploadExpiresAt: Instant,
        val expectedObjectPath: String,
        val requestId: String?,
    ) : PotholePhotoMetadataResult()

    /** 409 — server already has this report. Client cleans up locally. */
    data class AlreadyUploaded(val requestId: String?) : PotholePhotoMetadataResult()

    /** 400 — payload was malformed (size / sha mismatch / bad content type).
     *  Permanent failure; client marks the row failed_permanent. */
    data class ValidationFailed(
        val message: String?,
        val fieldErrors: Map<String, String>,
        val requestId: String?,
    ) : PotholePhotoMetadataResult()

    /** 429 — backend bucket exhausted; respect `Retry-After`. */
    data class RateLimited(
        val retryAfterSeconds: Double?,
        val requestId: String?,
    ) : PotholePhotoMetadataResult()

    data class ServerError(val statusCode: Int, val requestId: String?) : PotholePhotoMetadataResult()
    data class NetworkError(val cause: Throwable) : PotholePhotoMetadataResult()
}

/** Result of the actual `PUT bytes` step. */
sealed class PotholePhotoBytesResult {
    /** 200 / 201 — bytes accepted by Supabase Storage. */
    object Accepted : PotholePhotoBytesResult()

    /** 4xx / 5xx — caller decides whether to retry based on the status. */
    data class HttpError(val statusCode: Int, val body: String?) : PotholePhotoBytesResult()

    data class NetworkError(val cause: Throwable) : PotholePhotoBytesResult()
}
