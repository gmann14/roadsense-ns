package ca.roadsense.ns.api

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-format mirror of iOS `FeedbackSubmissionPayload`. Same JSON shape so the
 * `feedback` Edge Function does not need a platform branch.
 */
@Serializable
data class FeedbackSubmissionPayload(
    @SerialName("source") val source: String,
    @SerialName("category") val category: String,
    @SerialName("message") val message: String,
    @SerialName("reply_email") val replyEmail: String? = null,
    @SerialName("contact_consent") val contactConsent: Boolean,
    @SerialName("app_version") val appVersion: String,
    @SerialName("platform") val platform: String,
    @SerialName("locale") val locale: String? = null,
    @SerialName("route") val route: String? = null,
)

@Serializable
data class FeedbackSubmissionAcceptedResponse(
    @SerialName("id") val id: String,
    @SerialName("request_id") val requestId: String? = null,
)

@Serializable
data class FeedbackValidationErrorResponse(
    @SerialName("error") val error: String,
    @SerialName("message") val message: String? = null,
    @SerialName("request_id") val requestId: String? = null,
    @SerialName("field_errors") val fieldErrors: Map<String, String> = emptyMap(),
)

/**
 * Discriminated result so callers don't have to parse status codes inline.
 * Kotlin sealed class mirrors the Swift enum used in iOS.
 */
sealed class FeedbackSubmissionResult {
    data class Accepted(val id: String, val requestId: String?) : FeedbackSubmissionResult()
    data class ValidationFailed(
        val fieldErrors: Map<String, String>,
        val requestId: String?,
    ) : FeedbackSubmissionResult()
    data class RateLimited(val retryAfterSeconds: Double?, val requestId: String?) : FeedbackSubmissionResult()
    data class ServerError(val statusCode: Int, val requestId: String?) : FeedbackSubmissionResult()
    data class NetworkError(val cause: Throwable) : FeedbackSubmissionResult()
}
