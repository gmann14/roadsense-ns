package ca.roadsense.ns.api

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class UploadPolicyTest {
    @Test
    fun `200 succeeds`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(statusCode = 200, retryAfterSeconds = null),
            attemptNumber = 1,
        )
        assertEquals(UploadDisposition.Succeeded, disposition)
    }

    @Test
    fun `400 fails permanently`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(statusCode = 400, retryAfterSeconds = null),
            attemptNumber = 1,
        )
        assertEquals(UploadDisposition.FailedPermanent, disposition)
    }

    @Test
    fun `429 honors retry-after`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(statusCode = 429, retryAfterSeconds = 30.0),
            attemptNumber = 1,
        )
        val retry = assertIs<UploadDisposition.Retry>(disposition)
        assertEquals(30.0, retry.afterSeconds)
    }

    @Test
    fun `429 with no retry-after defaults to 60s`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(statusCode = 429, retryAfterSeconds = null),
            attemptNumber = 1,
        )
        val retry = assertIs<UploadDisposition.Retry>(disposition)
        assertEquals(60.0, retry.afterSeconds)
    }

    @Test
    fun `5xx retries with exponential backoff`() {
        val attempt1 = UploadPolicy.evaluate(
            UploadAttemptResult.Http(503, null),
            attemptNumber = 1,
        ) as UploadDisposition.Retry
        val attempt3 = UploadPolicy.evaluate(
            UploadAttemptResult.Http(503, null),
            attemptNumber = 3,
        ) as UploadDisposition.Retry
        assertEquals(1.0, attempt1.afterSeconds)
        assertEquals(4.0, attempt3.afterSeconds)
    }

    @Test
    fun `attempts above 5 fail permanently`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(503, null),
            attemptNumber = 6,
        )
        assertEquals(UploadDisposition.FailedPermanent, disposition)
    }

    @Test
    fun `network error retries`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.NetworkError,
            attemptNumber = 1,
        )
        assertIs<UploadDisposition.Retry>(disposition)
    }
}
