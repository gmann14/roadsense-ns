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
    fun `5xx never fails permanently and caps backoff at one hour`() {
        val attempt6 = UploadPolicy.evaluate(
            UploadAttemptResult.Http(503, null),
            attemptNumber = 6,
        )
        val retry6 = assertIs<UploadDisposition.Retry>(attempt6)
        assertEquals(32.0, retry6.afterSeconds)

        val attempt40 = UploadPolicy.evaluate(
            UploadAttemptResult.Http(503, null),
            attemptNumber = 40,
        )
        val retry40 = assertIs<UploadDisposition.Retry>(attempt40)
        assertEquals(UploadPolicy.MAX_RETRY_DELAY_SECONDS, retry40.afterSeconds)
    }

    @Test
    fun `503 honors retry-after like the photos_disabled gate sends`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(statusCode = 503, retryAfterSeconds = 21_600.0),
            attemptNumber = 12,
        )
        val retry = assertIs<UploadDisposition.Retry>(disposition)
        assertEquals(21_600.0, retry.afterSeconds)
    }

    @Test
    fun `404 keeps retrying with capped backoff instead of failing permanently`() {
        val disposition = UploadPolicy.evaluate(
            UploadAttemptResult.Http(statusCode = 404, retryAfterSeconds = null),
            attemptNumber = 10,
        )
        val retry = assertIs<UploadDisposition.Retry>(disposition)
        assertEquals(512.0, retry.afterSeconds)
    }

    @Test
    fun `network error retries and never goes permanent`() {
        val early = UploadPolicy.evaluate(
            UploadAttemptResult.NetworkError,
            attemptNumber = 1,
        )
        assertIs<UploadDisposition.Retry>(early)

        val late = UploadPolicy.evaluate(
            UploadAttemptResult.NetworkError,
            attemptNumber = 25,
        )
        val retry = assertIs<UploadDisposition.Retry>(late)
        assertEquals(UploadPolicy.MAX_RETRY_DELAY_SECONDS, retry.afterSeconds)
    }
}
