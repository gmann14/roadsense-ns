package ca.roadsense.ns.api

import kotlin.math.max
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
    fun evaluate(result: UploadAttemptResult, attemptNumber: Int): UploadDisposition =
        when (result) {
            is UploadAttemptResult.Http -> when (result.statusCode) {
                200 -> UploadDisposition.Succeeded
                400 -> UploadDisposition.FailedPermanent
                404 -> retryOrPermanent(attemptNumber)
                429 -> UploadDisposition.Retry(result.retryAfterSeconds ?: 60.0)
                in 500..599 -> retryOrPermanent(attemptNumber)
                else -> UploadDisposition.FailedPermanent
            }

            UploadAttemptResult.NetworkError -> retryOrPermanent(attemptNumber)
        }

    private fun retryOrPermanent(attemptNumber: Int): UploadDisposition {
        if (attemptNumber > 5) return UploadDisposition.FailedPermanent
        val exponent = max(attemptNumber - 1, 0)
        val delay = 2.0.pow(exponent.toDouble())
        return UploadDisposition.Retry(delay)
    }
}
