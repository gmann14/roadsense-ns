package ca.roadsense.ns.data.network

import ca.roadsense.ns.api.AppConfig
import ca.roadsense.ns.api.AppEnvironment
import ca.roadsense.ns.api.FeedbackSubmissionPayload
import ca.roadsense.ns.api.FeedbackSubmissionResult
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class BackendClientFeedbackTest {
    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() = server.shutdown()

    private fun client(): BackendClient {
        // Strip the trailing functions/v1 since the AppConfig appends it.
        val raw = server.url("/").toString().removeSuffix("/")
        // server.url("/") looks like http://127.0.0.1:PORT/ — we want the host
        // bare so functionsBaseURL = "$host/functions/v1".
        val config = AppConfig(
            environment = AppEnvironment.LOCAL,
            apiBaseURL = raw,
            mapboxAccessToken = "token",
            supabaseAnonKey = "anon",
        )
        return BackendClient(config)
    }

    private fun payload() = FeedbackSubmissionPayload(
        source = "android-settings",
        category = "bug",
        message = "hi",
        replyEmail = null,
        contactConsent = false,
        appVersion = "0.1.0 (1)",
        platform = "Android 14",
        locale = "en-CA",
        route = null,
    )

    @Test
    fun `201 response decodes as Accepted`() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(201)
                .setHeader("x-request-id", "req-201")
                .setBody("""{"id":"feedback-1","request_id":"req-201"}"""),
        )
        val result = client().submitFeedback(payload())
        assertTrue(result is FeedbackSubmissionResult.Accepted)
        result as FeedbackSubmissionResult.Accepted
        assertEquals("feedback-1", result.id)
        assertEquals("req-201", result.requestId)
    }

    @Test
    fun `400 response decodes as ValidationFailed`() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(400)
                .setHeader("x-request-id", "req-400")
                .setBody(
                    """{"error":"validation_failed","message":"x","request_id":"req-400","field_errors":{"message":"too_short"}}""",
                ),
        )
        val result = client().submitFeedback(payload())
        assertTrue(result is FeedbackSubmissionResult.ValidationFailed)
        result as FeedbackSubmissionResult.ValidationFailed
        assertEquals("too_short", result.fieldErrors["message"])
    }

    @Test
    fun `429 response with Retry-After becomes RateLimited`() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(429)
                .setHeader("Retry-After", "42")
                .setHeader("x-request-id", "req-429")
                .setBody(""),
        )
        val result = client().submitFeedback(payload())
        assertTrue(result is FeedbackSubmissionResult.RateLimited)
        result as FeedbackSubmissionResult.RateLimited
        assertEquals(42.0, result.retryAfterSeconds)
    }

    @Test
    fun `500 response surfaces as ServerError`() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        val result = client().submitFeedback(payload())
        assertTrue(result is FeedbackSubmissionResult.ServerError)
        assertEquals(500, (result as FeedbackSubmissionResult.ServerError).statusCode)
    }
}
