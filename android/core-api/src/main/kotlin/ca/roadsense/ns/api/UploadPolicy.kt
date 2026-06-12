package ca.roadsense.ns.api

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

sealed class UploadAttemptResult {
    data class Http(val statusCode: Int, val retryAfterSeconds: Double?) : UploadAttemptResult()
    data object NetworkError : UploadAttemptResult()
}

sealed class UploadDisposition {
    data object Succeeded : UploadDisposition()
    data class Retry(val afterSeconds: Double) : UploadDisposition()
    data object FailedPermanent : UploadDisposition()
}

object UploadPolicy {
    /**
     * Upper bound for exponential retry backoff (1 hour). Transport-level
     * failures (offline, timeout, connection refused) and transient server
     * errors (5xx, missing route) never become [UploadDisposition.FailedPermanent] —
     * driving offline in rural coverage gaps is the core use case, so only an
     * explicit server rejection (4xx validation) may strand a batch. Mirrors
     * the iOS UploadPolicy semantics (ios commit ef0ce7f / d4d0090).
     */
    const val MAX_RETRY_DELAY_SECONDS: Double = 3_600.0

    fun evaluate(result: UploadAttemptResult, attemptNumber: Int): UploadDisposition =
        when (result) {
            is UploadAttemptResult.Http -> when (result.statusCode) {
                200 -> UploadDisposition.Succeeded
                400 -> UploadDisposition.FailedPermanent
                404 -> UploadDisposition.Retry(backoffDelay(attemptNumber))
                429 -> UploadDisposition.Retry(result.retryAfterSeconds ?: 60.0)
                in 500..599 -> UploadDisposition.Retry(
                    result.retryAfterSeconds ?: backoffDelay(attemptNumber)
                )
                else -> UploadDisposition.FailedPermanent
            }

            UploadAttemptResult.NetworkError -> UploadDisposition.Retry(backoffDelay(attemptNumber))
        }

    private fun backoffDelay(attemptNumber: Int): Double {
        val exponent = min(max(attemptNumber - 1, 0), 16)
        return min(2.0.pow(exponent.toDouble()), MAX_RETRY_DELAY_SECONDS)
    }
}
