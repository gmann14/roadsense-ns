package ca.roadsense.ns.upload

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.api.NetworkPathSnapshot
import ca.roadsense.ns.api.NetworkPathStatus
import ca.roadsense.ns.api.UploadReadingsRequest
import ca.roadsense.ns.api.UploadReadingsResponse
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.data.room.UploadBatchState
import kotlinx.coroutines.test.runTest
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import retrofit2.Response
import java.io.IOException
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class UploadDrainCoordinatorTest {
    private lateinit var db: RoadSenseDatabase
    private val now = Instant.parse("2026-05-01T00:00:00Z")
    private val fixedClock = object : UploadDrainCoordinator.Clock {
        override fun now(): Instant = now
    }

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            RoadSenseDatabase::class.java,
        )
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    private val online = NetworkPathSnapshot(NetworkPathStatus.SATISFIED, isExpensive = false)
    private val offline = NetworkPathSnapshot(NetworkPathStatus.UNSATISFIED, isExpensive = false)

    private fun reading(id: UUID = UUID.randomUUID()) = ReadingEntity(
        id = id,
        latitude = 44.6488,
        longitude = -63.5752,
        roughnessRMS = 0.5,
        speedKMH = 50.0,
        heading = 90.0,
        gpsAccuracyM = 5.0,
        isPothole = false,
        potholeMagnitude = null,
        recordedAt = now,
    )

    private fun coordinator(rpc: UploadReadingsRpc) = UploadDrainCoordinator(
        readingDao = db.readingDao(),
        batchDao = db.uploadBatchDao(),
        uploadReadingsRpc = rpc,
        deviceTokenProvider = { "test-token" },
        clock = fixedClock,
    )

    private fun successResponse(): Response<UploadReadingsResponse> =
        Response.success(
            UploadReadingsResponse(
                batchId = UUID.fromString("00000000-0000-0000-0000-000000000001"),
                accepted = 0,
                rejected = 0,
                duplicate = false,
                rejectedReasons = emptyMap(),
            )
        )

    private fun errorResponse(code: Int, retryAfterSeconds: Double? = null): Response<UploadReadingsResponse> {
        val raw = okhttp3.Response.Builder()
            .request(Request.Builder().url("http://test/").build())
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("err")
            .apply {
                if (retryAfterSeconds != null) {
                    headers(Headers.headersOf("Retry-After", retryAfterSeconds.toString()))
                }
            }
            .body("".toResponseBody("application/json".toMediaType()))
            .build()
        return Response.error("".toResponseBody("application/json".toMediaType()), raw)
    }

    @Test
    fun `drain returns NothingToDo when no readings pending`() = runTest {
        val outcome = coordinator { successResponse() }.drainOnce(online)
        assertTrue(outcome is UploadDrainCoordinator.Outcome.NothingToDo)
    }

    @Test
    fun `drain returns Offline when network down`() = runTest {
        db.readingDao().insertAll(listOf(reading()))
        val outcome = coordinator { successResponse() }.drainOnce(offline)
        assertTrue(outcome is UploadDrainCoordinator.Outcome.Offline)
    }

    @Test
    fun `200 marks readings uploaded and batch succeeded`() = runTest {
        val r = reading()
        db.readingDao().insert(r)
        var sent: UploadReadingsRequest? = null
        val outcome = coordinator { request ->
            sent = request
            successResponse()
        }.drainOnce(online)

        assertTrue(outcome is UploadDrainCoordinator.Outcome.BatchSucceeded)
        val outcomeT = outcome as UploadDrainCoordinator.Outcome.BatchSucceeded
        assertNotNull(sent)
        assertEquals(1, sent!!.readings.size)
        assertEquals(r.latitude, sent!!.readings.first().lat)

        val updated = db.readingDao().findById(r.id)!!
        assertEquals(now, updated.uploadedAt)
        val batch = db.uploadBatchDao().findById(outcomeT.batchId)!!
        assertEquals(UploadBatchState.SUCCEEDED, batch.state)
    }

    @Test
    fun `500 schedules a retry with backoff and keeps the batch assignment`() = runTest {
        val r = reading()
        db.readingDao().insert(r)
        val outcome = coordinator { errorResponse(503) }.drainOnce(online)

        assertTrue(outcome is UploadDrainCoordinator.Outcome.BatchRetry)
        val outcomeT = outcome as UploadDrainCoordinator.Outcome.BatchRetry
        // attempt 1 backoff = 2^0 = 1 second
        assertEquals(now.plusMillis(1_000), outcomeT.nextAttemptAt)

        val released = db.readingDao().findById(r.id)!!
        assertNotNull(released.uploadBatchId, "batch assignment should be retained for retry")

        val batch = db.uploadBatchDao().findById(outcomeT.batchId)!!
        assertEquals(UploadBatchState.PENDING, batch.state)
        assertEquals(503, batch.lastHttpStatusCode)
    }

    @Test
    fun `pending retry waits for backoff before sending again`() = runTest {
        val r = reading()
        db.readingDao().insert(r)
        val first = coordinator { errorResponse(503) }.drainOnce(online)
        assertTrue(first is UploadDrainCoordinator.Outcome.BatchRetry)

        val sent = mutableListOf<UploadReadingsRequest>()
        val second = coordinator { request ->
            sent.add(request)
            successResponse()
        }.drainOnce(online)

        assertTrue(second is UploadDrainCoordinator.Outcome.NothingToDo)
        assertTrue(sent.isEmpty(), "retry should not run before next_attempt_at")
    }

    @Test
    fun `400 marks the batch failed permanent`() = runTest {
        val r = reading()
        db.readingDao().insert(r)
        val outcome = coordinator { errorResponse(400) }.drainOnce(online)

        assertTrue(outcome is UploadDrainCoordinator.Outcome.BatchFailedPermanent)
        val batch = db.uploadBatchDao().findById((outcome as UploadDrainCoordinator.Outcome.BatchFailedPermanent).batchId)!!
        assertEquals(UploadBatchState.FAILED_PERMANENT, batch.state)
    }

    @Test
    fun `network IOException retries with backoff`() = runTest {
        val r = reading()
        db.readingDao().insert(r)
        val outcome = coordinator { throw IOException("connection reset") }.drainOnce(online)
        assertTrue(outcome is UploadDrainCoordinator.Outcome.BatchRetry)
    }
}
