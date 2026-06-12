package ca.roadsense.ns.feedback

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.api.FeedbackSubmissionResult
import ca.roadsense.ns.data.room.FeedbackUploadState
import ca.roadsense.ns.data.room.RoadSenseDatabase
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class FeedbackQueueTest {
    private lateinit var db: RoadSenseDatabase
    private val now = Instant.parse("2026-05-01T00:00:00Z")
    private val clock = { now }

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            RoadSenseDatabase::class.java,
        ).allowMainThreadQueries().build()
    }

    @After
    fun tearDown() = db.close()

    @Test
    fun `enqueue adds a pending row`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue(
            source = "android-settings",
            category = "bug",
            message = "test",
            replyEmail = null,
            contactConsent = false,
            locale = "en-CA",
            route = null,
        )

        val row = db.feedbackDao().findById(id)!!
        assertEquals(FeedbackUploadState.PENDING.wireValue, row.uploadState)
        assertEquals("test", row.message)
        assertEquals(1, queue.pendingCount())
    }

    @Test
    fun `drainer marks a 201 row as SUBMITTED`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        val drainer = FeedbackQueueDrainer(
            dao = db.feedbackDao(),
            submitter = { FeedbackSubmissionResult.Accepted("server-id", "req-1") },
            clientAppVersion = "0.1.0 (1)",
            platform = "Android 14",
            clock = clock,
        )

        val outcomes = drainer.drain()
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.first() is FeedbackQueueDrainer.Outcome.Submitted)

        val row = db.feedbackDao().findById(id)!!
        assertEquals(FeedbackUploadState.SUBMITTED.wireValue, row.uploadState)
        assertNotNull(row.lastAttemptAt)
        assertEquals("req-1", row.lastRequestId)
    }

    @Test
    fun `validation failure flips the row to FAILED_PERMANENT`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        val drainer = FeedbackQueueDrainer(
            dao = db.feedbackDao(),
            submitter = {
                FeedbackSubmissionResult.ValidationFailed(
                    fieldErrors = mapOf("message" to "too_short"),
                    requestId = "req-2",
                )
            },
            clientAppVersion = "0.1.0",
            platform = "Android 14",
            clock = clock,
        )
        drainer.drain()

        val row = db.feedbackDao().findById(id)!!
        assertEquals(FeedbackUploadState.FAILED_PERMANENT.wireValue, row.uploadState)
        assertNotNull(row.lastFieldErrors)
        assertTrue(row.lastFieldErrors!!.contains("too_short"))
    }

    @Test
    fun `rate-limited rows reschedule with retryAfter`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        val drainer = FeedbackQueueDrainer(
            dao = db.feedbackDao(),
            submitter = { FeedbackSubmissionResult.RateLimited(retryAfterSeconds = 30.0, requestId = "req-3") },
            clientAppVersion = "0.1.0",
            platform = "Android 14",
            clock = clock,
        )
        drainer.drain()

        val row = db.feedbackDao().findById(id)!!
        assertEquals(FeedbackUploadState.PENDING.wireValue, row.uploadState)
        assertEquals(now.plusSeconds(30), row.nextAttemptAt)
    }

    @Test
    fun `network errors reschedule with exponential backoff`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        val drainer = FeedbackQueueDrainer(
            dao = db.feedbackDao(),
            submitter = { FeedbackSubmissionResult.NetworkError(IOException("offline")) },
            clientAppVersion = "0.1.0",
            platform = "Android 14",
            clock = clock,
        )
        drainer.drain()

        val row = db.feedbackDao().findById(id)!!
        assertEquals(FeedbackUploadState.PENDING.wireValue, row.uploadState)
        assertNotNull(row.nextAttemptAt)
        // attempt 1 → 2^0 = 1s
        assertEquals(now.plusSeconds(1), row.nextAttemptAt)
    }

    @Test
    fun `network errors stop retrying after the permanent failure threshold`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        db.feedbackDao().update(
            db.feedbackDao().findById(id)!!.copy(uploadAttemptCount = 5),
        )
        val drainer = FeedbackQueueDrainer(
            dao = db.feedbackDao(),
            submitter = { FeedbackSubmissionResult.NetworkError(IOException("offline")) },
            clientAppVersion = "0.1.0",
            platform = "Android 14",
            clock = clock,
        )

        val outcomes = drainer.drain()

        assertTrue(outcomes.first() is FeedbackQueueDrainer.Outcome.FailedPermanent)
        val row = db.feedbackDao().findById(id)!!
        assertEquals(FeedbackUploadState.FAILED_PERMANENT.wireValue, row.uploadState)
        assertNull(row.nextAttemptAt)
    }

    @Test
    fun `pending() respects nextAttemptAt`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        // Schedule into the future.
        db.feedbackDao().update(
            db.feedbackDao().findById(id)!!.copy(
                nextAttemptAt = now.plusSeconds(120),
            ),
        )
        val due = db.feedbackDao().pending(FeedbackUploadState.PENDING.wireValue, now)
        assertEquals(emptyList(), due)
    }

    @Test
    fun `delete removes the row`() = runTest {
        val queue = FeedbackQueue(db.feedbackDao(), clock)
        val id = queue.enqueue("settings", "bug", "msg", null, false, "en-CA", null)
        assertTrue(queue.delete(id))
        assertNull(db.feedbackDao().findById(id))
    }
}
