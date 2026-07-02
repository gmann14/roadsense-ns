package ca.roadsense.ns.upload

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.api.NetworkPathSnapshot
import ca.roadsense.ns.api.NetworkPathStatus
import ca.roadsense.ns.api.UploadReadingsRequest
import ca.roadsense.ns.api.UploadReadingsResponse
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.data.room.UploadBatchEntity
import ca.roadsense.ns.data.room.UploadBatchState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
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
import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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
        database = db,
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

    @Test
    fun `non-IOException during upload retries instead of stranding the batch IN_FLIGHT`() = runTest {
        val r = reading()
        db.readingDao().insert(r)

        // Before the fix, only IOException was caught — a serialization
        // error or any other RuntimeException would propagate uncaught,
        // leaving markAttempt(IN_FLIGHT) as the last write Room ever saw for
        // this batch. Assert it's retryable, not stuck.
        val outcome = coordinator {
            throw IllegalStateException("unexpected serialization failure")
        }.drainOnce(online)

        assertTrue(outcome is UploadDrainCoordinator.Outcome.BatchRetry, "non-IO exception should be treated as retryable")
        val outcomeT = outcome as UploadDrainCoordinator.Outcome.BatchRetry
        val batch = db.uploadBatchDao().findById(outcomeT.batchId)!!
        assertEquals(UploadBatchState.PENDING, batch.state, "batch must not be left IN_FLIGHT")
    }

    @Test
    fun `CancellationException during upload is rethrown, not swallowed`() = runTest {
        val r = reading()
        db.readingDao().insert(r)

        assertFailsWith<CancellationException> {
            coordinator { throw CancellationException("worker cancelled") }.drainOnce(online)
        }
    }

    @Test
    fun `a batch stranded IN_FLIGHT past the staleness threshold is reclaimed and retried`() = runTest {
        val r = reading()
        db.readingDao().insert(r)

        val batchId = UUID.randomUUID()
        db.uploadBatchDao().insert(
            UploadBatchEntity(
                id = batchId,
                state = UploadBatchState.IN_FLIGHT,
                createdAt = now.minus(Duration.ofMinutes(10)),
                lastAttemptAt = now.minus(Duration.ofMinutes(10)),
                attemptCount = 1,
                readingCount = 1,
            ),
        )
        db.readingDao().assignBatch(listOf(r.id), batchId)

        var uploaded = false
        val outcome = coordinator {
            uploaded = true
            successResponse()
        }.drainOnce(online)

        assertTrue(uploaded, "reclaimed batch should be retried, not left stranded")
        assertTrue(outcome is UploadDrainCoordinator.Outcome.BatchSucceeded)
        assertEquals(batchId, (outcome as UploadDrainCoordinator.Outcome.BatchSucceeded).batchId)
    }

    @Test
    fun `two concurrent drains never assign the same reading to two different batches`() = runTest {
        val readings = (1..5).map { reading() }
        db.readingDao().insertAll(readings)

        // Two coordinators sharing the same underlying database, racing to
        // drain the same pending readings — this is the shape of two
        // WorkManager workers running concurrently before enqueueUniqueWork
        // was wired up. Without the @Transaction-equivalent
        // (database.withTransaction) around select+insert+assign, both could
        // read the same pending rows before either assigns a batch.
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()

        val first = async {
            coordinator {
                firstStarted.complete(Unit)
                releaseFirst.await()
                successResponse()
            }.drainOnce(online)
        }
        firstStarted.await()

        val second = async {
            coordinator { successResponse() }.drainOnce(online)
        }

        releaseFirst.complete(Unit)
        val firstOutcome = first.await()
        val secondOutcome = second.await()

        val batchIds = listOfNotNull(
            (firstOutcome as? UploadDrainCoordinator.Outcome.BatchSucceeded)?.batchId,
            (secondOutcome as? UploadDrainCoordinator.Outcome.BatchSucceeded)?.batchId,
        )

        // Whichever readings each batch picked up, no reading may ever be
        // assigned to more than one upload_batches row.
        val assignedBatchIdsPerReading = readings.map { db.readingDao().findById(it.id)!!.uploadBatchId }
        assertTrue(assignedBatchIdsPerReading.all { it != null }, "every reading should end up assigned to exactly one batch")

        // No reading appears in more than one batch's reading set.
        val allBatchReadingIds = batchIds.flatMap { db.readingDao().byBatch(it).map(ReadingEntity::id) }
        assertEquals(allBatchReadingIds.size, allBatchReadingIds.distinct().size, "a reading must not appear in two batches")
        assertEquals(readings.size, allBatchReadingIds.size, "every reading must be picked up by exactly one of the two drains")
    }

    @Test
    fun `a batch IN_FLIGHT for less than the staleness threshold is left alone`() = runTest {
        val r = reading()
        db.readingDao().insert(r)

        val batchId = UUID.randomUUID()
        db.uploadBatchDao().insert(
            UploadBatchEntity(
                id = batchId,
                state = UploadBatchState.IN_FLIGHT,
                createdAt = now.minus(Duration.ofSeconds(30)),
                lastAttemptAt = now.minus(Duration.ofSeconds(30)),
                attemptCount = 1,
                readingCount = 1,
            ),
        )
        db.readingDao().assignBatch(listOf(r.id), batchId)

        var uploaded = false
        val outcome = coordinator {
            uploaded = true
            successResponse()
        }.drainOnce(online)

        // The recent IN_FLIGHT batch isn't reclaimed, and its reading is
        // assigned so it won't show up as a fresh pending batch either.
        assertTrue(!uploaded, "recently-attempted IN_FLIGHT batch should not be re-uploaded concurrently")
        assertTrue(outcome is UploadDrainCoordinator.Outcome.NothingToDo)
        val batch = db.uploadBatchDao().findById(batchId)!!
        assertEquals(UploadBatchState.IN_FLIGHT, batch.state)
    }
}
