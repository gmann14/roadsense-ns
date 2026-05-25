package ca.roadsense.ns.pothole

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.api.PotholePhotoBytesResult
import ca.roadsense.ns.api.PotholePhotoMetadataResult
import ca.roadsense.ns.data.room.PhotoUploadState
import ca.roadsense.ns.data.room.PotholePhotoEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class PotholePhotoCoordinatorTest {

    private lateinit var db: RoadSenseDatabase
    private lateinit var tempDir: File
    private val now = Instant.parse("2026-05-01T00:00:00Z")
    private val clock = { now }
    private val deviceToken = UUID.fromString("a78f9e2b-4c6d-11ec-81d3-0242ac130003")

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            RoadSenseDatabase::class.java,
        ).allowMainThreadQueries().build()
        tempDir = File.createTempFile("photos", "").apply {
            delete(); mkdirs()
        }
    }

    @After
    fun tearDown() {
        db.close()
        tempDir.deleteRecursively()
    }

    private fun makePhotoRow(
        id: UUID = UUID.randomUUID(),
        fileBytes: ByteArray = ByteArray(2048) { 0x7F },
        state: PhotoUploadState = PhotoUploadState.PENDING_METADATA,
    ): PotholePhotoEntity {
        val file = File(tempDir, "$id.jpg").apply { writeBytes(fileBytes) }
        return PotholePhotoEntity(
            id = id,
            segmentId = null,
            photoFilePath = file.absolutePath,
            latitude = 44.6488,
            longitude = -63.5752,
            accuracyM = 6.8,
            capturedAt = now,
            uploadState = state.wireValue,
            byteSize = fileBytes.size.toLong(),
            sha256Hex = "deadbeef",
        )
    }

    private fun buildCoordinator(
        metadata: PotholePhotoMetadataRpc,
        bytes: PotholePhotoBytesRpc = PotholePhotoBytesRpc { _, _ -> PotholePhotoBytesResult.Accepted },
    ): PotholePhotoCoordinator = PotholePhotoCoordinator(
        dao = db.potholePhotoDao(),
        metadataRpc = metadata,
        bytesRpc = bytes,
        deviceTokenProvider = { deviceToken.toString() },
        clientAppVersion = "0.1.0 (1)",
        clientOSVersion = "Android 14",
        clock = clock,
    )

    @Test
    fun `happy path uploads metadata then bytes and flips to pending_moderation`() = runTest {
        val photo = makePhotoRow()
        db.potholePhotoDao().insert(photo)

        var puts = 0
        val coordinator = buildCoordinator(
            metadata = PotholePhotoMetadataRpc {
                PotholePhotoMetadataResult.SignedURLIssued(
                    reportId = photo.id,
                    uploadURL = "https://example/upload?token=xyz",
                    uploadExpiresAt = now.plusSeconds(3600),
                    expectedObjectPath = "pending/${photo.id}.jpg",
                    requestId = "req-1",
                )
            },
            bytes = PotholePhotoBytesRpc { _, _ -> puts++; PotholePhotoBytesResult.Accepted },
        )

        val outcomes = coordinator.drain()
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.first() is PotholePhotoCoordinator.Outcome.Succeeded)
        assertEquals(1, puts)

        val stored = db.potholePhotoDao().findById(photo.id)!!
        assertEquals(PhotoUploadState.PENDING_MODERATION.wireValue, stored.uploadState)
        assertEquals("pending/${photo.id}.jpg", stored.expectedObjectPath)
        assertEquals("req-1", stored.lastRequestId)
        assertNull(stored.nextAttemptAt)
    }

    @Test
    fun `already_uploaded promotes the row without putting bytes`() = runTest {
        val photo = makePhotoRow()
        db.potholePhotoDao().insert(photo)

        var puts = 0
        val coordinator = buildCoordinator(
            metadata = PotholePhotoMetadataRpc {
                PotholePhotoMetadataResult.AlreadyUploaded(requestId = "req-2")
            },
            bytes = PotholePhotoBytesRpc { _, _ -> puts++; PotholePhotoBytesResult.Accepted },
        )

        val outcomes = coordinator.drain()
        assertTrue(outcomes.first() is PotholePhotoCoordinator.Outcome.Succeeded)
        assertEquals(0, puts) // server already has the bytes
        val stored = db.potholePhotoDao().findById(photo.id)!!
        assertEquals(PhotoUploadState.PENDING_MODERATION.wireValue, stored.uploadState)
    }

    @Test
    fun `validation_failed flips the row to failed_permanent and never retries`() = runTest {
        val photo = makePhotoRow()
        db.potholePhotoDao().insert(photo)

        val coordinator = buildCoordinator(
            metadata = PotholePhotoMetadataRpc {
                PotholePhotoMetadataResult.ValidationFailed(
                    message = "sha256 mismatch",
                    fieldErrors = mapOf("sha256" to "mismatch"),
                    requestId = "req-3",
                )
            },
        )
        val outcomes = coordinator.drain()
        val outcome = outcomes.first()
        assertTrue(outcome is PotholePhotoCoordinator.Outcome.FailedPermanent)

        val stored = db.potholePhotoDao().findById(photo.id)!!
        assertEquals(PhotoUploadState.FAILED_PERMANENT.wireValue, stored.uploadState)
    }

    @Test
    fun `rate_limited schedules a retry with backoff and keeps row pending_metadata`() = runTest {
        val photo = makePhotoRow()
        db.potholePhotoDao().insert(photo)

        val coordinator = buildCoordinator(
            metadata = PotholePhotoMetadataRpc {
                PotholePhotoMetadataResult.RateLimited(retryAfterSeconds = 30.0, requestId = "req-4")
            },
        )
        val outcomes = coordinator.drain()
        val outcome = outcomes.first()
        assertTrue(outcome is PotholePhotoCoordinator.Outcome.Retry)

        val stored = db.potholePhotoDao().findById(photo.id)!!
        assertEquals(PhotoUploadState.PENDING_METADATA.wireValue, stored.uploadState)
        assertNotNull(stored.nextAttemptAt)
        // After-seconds floor; we don't assert the precise backoff curve here
        // (UploadPolicy owns that math) — just that it's in the future.
        assertTrue(stored.nextAttemptAt!!.isAfter(now))
    }

    @Test
    fun `missing photo file flips to failed_permanent and does not call metadata`() = runTest {
        val photo = makePhotoRow().copy(photoFilePath = File(tempDir, "does-not-exist.jpg").absolutePath)
        db.potholePhotoDao().insert(photo)

        var metadataCalls = 0
        val coordinator = buildCoordinator(
            metadata = PotholePhotoMetadataRpc {
                metadataCalls++
                PotholePhotoMetadataResult.AlreadyUploaded(requestId = null)
            },
        )

        val outcomes = coordinator.drain()
        assertTrue(outcomes.first() is PotholePhotoCoordinator.Outcome.FileMissing)
        assertEquals(0, metadataCalls)
        val stored = db.potholePhotoDao().findById(photo.id)!!
        assertEquals(PhotoUploadState.FAILED_PERMANENT.wireValue, stored.uploadState)
    }

    @Test
    fun `bytes failure retries without touching the metadata state`() = runTest {
        val photo = makePhotoRow()
        db.potholePhotoDao().insert(photo)

        val coordinator = buildCoordinator(
            metadata = PotholePhotoMetadataRpc {
                PotholePhotoMetadataResult.SignedURLIssued(
                    reportId = photo.id,
                    uploadURL = "https://example/upload?token=xyz",
                    uploadExpiresAt = now.plusSeconds(3600),
                    expectedObjectPath = "pending/${photo.id}.jpg",
                    requestId = "req-1",
                )
            },
            bytes = PotholePhotoBytesRpc { _, _ ->
                PotholePhotoBytesResult.HttpError(statusCode = 503, body = null)
            },
        )
        val outcomes = coordinator.drain()
        assertTrue(outcomes.first() is PotholePhotoCoordinator.Outcome.Retry)
        val stored = db.potholePhotoDao().findById(photo.id)!!
        assertEquals(PhotoUploadState.PENDING_METADATA.wireValue, stored.uploadState)
        assertFalse(stored.expectedObjectPath != null) // not yet flipped
    }
}
