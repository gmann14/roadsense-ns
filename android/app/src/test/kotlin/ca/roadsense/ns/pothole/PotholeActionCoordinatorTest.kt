package ca.roadsense.ns.pothole

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.api.PotholeActionUploadResponse
import ca.roadsense.ns.data.room.PotholeActionUploadState
import ca.roadsense.ns.data.room.RoadSenseDatabase
import kotlinx.coroutines.test.runTest
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class PotholeActionCoordinatorTest {
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

    private fun successResponse(actionId: UUID, reportId: UUID = UUID.randomUUID()): Response<PotholeActionUploadResponse> =
        Response.success(
            PotholeActionUploadResponse(
                actionId = actionId,
                potholeReportId = reportId,
                status = "accepted",
            ),
        )

    private fun errorResponse(code: Int): Response<PotholeActionUploadResponse> {
        val raw = okhttp3.Response.Builder()
            .request(Request.Builder().url("http://test/").build())
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("err")
            .body("".toResponseBody("application/json".toMediaType()))
            .build()
        return Response.error("".toResponseBody("application/json".toMediaType()), raw)
    }

    private fun buildCoordinator(rpc: PotholeActionRpc): PotholeActionCoordinator =
        PotholeActionCoordinator(
            dao = db.potholeActionDao(),
            rpc = rpc,
            deviceTokenProvider = { "test-token" },
            clientAppVersion = "0.1.0 (1)",
            clientOSVersion = "Android 14",
            clock = clock,
        )

    @Test
    fun `manual report flows from PENDING_UNDO to PENDING_UPLOAD on undo expiry`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))

        // Inside the window: nothing happens.
        assertEquals(0, repo.promoteExpiredUndos())

        // Outside the window: row promoted.
        val expiredClock = { now.plusSeconds(20) }
        val expired = PotholeActionRepository(db.potholeActionDao(), expiredClock)
        assertEquals(1, expired.promoteExpiredUndos())

        val row = db.potholeActionDao().findById(id)!!
        assertEquals(PotholeActionUploadState.PENDING_UPLOAD.wireValue, row.uploadState)
    }

    @Test
    fun `undo within window deletes the row`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))
        assertTrue(repo.undo(id))
        assertNull(db.potholeActionDao().findById(id))
    }

    @Test
    fun `undo after window does not delete`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))

        val late = PotholeActionRepository(db.potholeActionDao(), { now.plusSeconds(20) })
        assertTrue(!late.undo(id))
        assertNotNull(db.potholeActionDao().findById(id))
    }

    @Test
    fun `coordinator drains a PENDING_UPLOAD action and marks it submitted`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))
        // Force into PENDING_UPLOAD state by simulating elapsed undo window.
        PotholeActionRepository(db.potholeActionDao(), { now.plusSeconds(20) })
            .promoteExpiredUndos()

        val coordinator = buildCoordinator { request ->
            successResponse(request.actionId, UUID.randomUUID())
        }
        val outcomes = coordinator.drain()
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.first() is PotholeActionCoordinator.Outcome.Submitted)

        val row = db.potholeActionDao().findById(id)!!
        assertEquals(PotholeActionUploadState.SUBMITTED.wireValue, row.uploadState)
        assertNotNull(row.uploadedAt)
        assertNotNull(row.potholeReportId)
        assertEquals(listOf(PotholeActionCoordinator.Outcome.NothingToDo), coordinator.drain())
    }

    @Test
    fun `503 sets a backoff and keeps the row PENDING_UPLOAD`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))
        PotholeActionRepository(db.potholeActionDao(), { now.plusSeconds(20) })
            .promoteExpiredUndos()

        val coordinator = buildCoordinator { errorResponse(503) }
        val outcomes = coordinator.drain()
        assertTrue(outcomes.first() is PotholeActionCoordinator.Outcome.Retry)

        val row = db.potholeActionDao().findById(id)!!
        assertEquals(PotholeActionUploadState.PENDING_UPLOAD.wireValue, row.uploadState)
        assertNotNull(row.nextAttemptAt)
    }

    @Test
    fun `400 marks the action FAILED_PERMANENT`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))
        PotholeActionRepository(db.potholeActionDao(), { now.plusSeconds(20) })
            .promoteExpiredUndos()

        val coordinator = buildCoordinator { errorResponse(400) }
        val outcomes = coordinator.drain()
        assertTrue(outcomes.first() is PotholeActionCoordinator.Outcome.FailedPermanent)
        val row = db.potholeActionDao().findById(id)!!
        assertEquals(PotholeActionUploadState.FAILED_PERMANENT.wireValue, row.uploadState)
    }

    @Test
    fun `IOException retries with backoff`() = runTest {
        val repo = PotholeActionRepository(db.potholeActionDao(), clock)
        val id = repo.reportPothole(PotholeLocation(44.65, -63.58, 5.0))
        PotholeActionRepository(db.potholeActionDao(), { now.plusSeconds(20) })
            .promoteExpiredUndos()

        val coordinator = buildCoordinator { throw IOException("net") }
        val outcomes = coordinator.drain()
        assertTrue(outcomes.first() is PotholeActionCoordinator.Outcome.Retry)
        val row = db.potholeActionDao().findById(id)!!
        assertEquals(PotholeActionUploadState.PENDING_UPLOAD.wireValue, row.uploadState)
        assertNotNull(row.nextAttemptAt)
    }
}
