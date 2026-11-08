package ca.roadsense.ns.data

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.collection.DriveSessionLifecycle
import ca.roadsense.ns.collection.DriveSessionSealer
import ca.roadsense.ns.data.room.DeviceTokenEntity
import ca.roadsense.ns.data.room.DriveSessionEntity
import ca.roadsense.ns.data.room.FeedbackEntity
import ca.roadsense.ns.data.room.FeedbackUploadState
import ca.roadsense.ns.data.room.PhotoUploadState
import ca.roadsense.ns.data.room.PotholeActionUploadState
import ca.roadsense.ns.data.room.PotholePhotoEntity
import ca.roadsense.ns.data.room.PrivacyZoneEntity
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.data.room.UploadBatchEntity
import ca.roadsense.ns.data.room.UploadBatchState
import ca.roadsense.ns.pothole.PotholeActionCoordinator
import ca.roadsense.ns.pothole.PotholeLocation
import ca.roadsense.ns.sensor.LocationSample
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class LocalDataMaintenanceTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var db: RoadSenseDatabase
    private lateinit var lifecycle: DriveSessionLifecycle
    private val now = Instant.parse("2026-06-01T00:00:00Z")
    private val old = now.minus(Duration.ofDays(45))
    private val recent = now.minus(Duration.ofDays(5))

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            RoadSenseDatabase::class.java,
        ).allowMainThreadQueries().build()
        lifecycle = DriveSessionLifecycle(
            driveSessionDao = db.driveSessionDao(),
            readingDao = db.readingDao(),
            sealer = DriveSessionSealer(db, db.driveSessionDao(), db.readingDao()),
        )
    }

    @After
    fun tearDown() = db.close()

    private fun reading(
        recordedAt: Instant,
        uploadedAt: Instant? = null,
        trimmedAt: Instant? = null,
        dropped: Boolean = false,
        batchId: UUID? = null,
    ) = ReadingEntity(
        id = UUID.randomUUID(),
        latitude = 44.68,
        longitude = -63.60,
        roughnessRMS = 0.5,
        speedKMH = 50.0,
        heading = 90.0,
        gpsAccuracyM = 5.0,
        isPothole = false,
        potholeMagnitude = null,
        recordedAt = recordedAt,
        driveSessionId = UUID.randomUUID(),
        uploadBatchId = batchId,
        uploadedAt = uploadedAt,
        uploadReadyAt = recordedAt,
        endpointTrimmedAt = trimmedAt,
        droppedByPrivacyZone = dropped,
    )

    @Test
    fun `wipe clears every table, deletes photo files and blocks the live session`() = runTest {
        val photoDir = tmp.newFolder("pothole-photos")
        val photo = photoDir.resolve("a.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val session = lifecycle.openSession(
            LocationSample(now.epochSecond.toDouble(), 44.6, -63.5, 5.0, 40.0, 0.0),
        )
        db.readingDao().insert(reading(recordedAt = now))
        db.potholePhotoDao().insert(
            PotholePhotoEntity(
                id = UUID.randomUUID(),
                latitude = 44.6,
                longitude = -63.5,
                accuracyM = 5.0,
                capturedAt = now,
                photoFilePath = photo.absolutePath,
                uploadState = PhotoUploadState.PENDING_METADATA.wireValue,
                byteSize = 3,
                sha256Hex = "00",
            ),
        )
        db.privacyZoneDao().upsert(
            PrivacyZoneEntity(UUID.randomUUID(), "home", 44.6, -63.5, 250.0, now),
        )
        db.feedbackDao().insert(
            FeedbackEntity(
                id = UUID.randomUUID(),
                source = "settings",
                category = "bug",
                message = "test",
                contactConsent = false,
                createdAt = now,
            ),
        )
        db.potholeActionDao().insert(
            PotholeActionCoordinator.manualReport(PotholeLocation(44.6, -63.5, 5.0), now),
        )

        LocalDataWiper(db, lifecycle, photoDir).wipe()

        assertEquals(0, db.readingDao().pendingCount())
        assertTrue(db.privacyZoneDao().list().isEmpty())
        assertTrue(db.driveSessionDao().recent(10).isEmpty())
        assertTrue(db.potholePhotoDao().allFilePaths().isEmpty())
        assertEquals(0, db.feedbackDao().pendingCount(FeedbackUploadState.PENDING.wireValue))
        assertNull(db.potholeActionDao().findById(UUID.randomUUID()))
        assertFalse(photo.exists(), "photo bytes must be deleted with their rows")
        assertFalse(photoDir.exists())
        assertFalse(lifecycle.recordReading(reading(now).copy(driveSessionId = session)))
    }

    @Test
    fun `wipe tolerates a missing photo directory`() = runTest {
        LocalDataWiper(db, lifecycle, tmp.root.resolve("never-created")).wipe()
        assertTrue(db.driveSessionDao().recent(1).isEmpty())
    }

    @Test
    fun `prune removes only finished data older than the retention window`() = runTest {
        val dao = db.readingDao()
        val oldUploaded = reading(old, uploadedAt = old)
        val recentUploaded = reading(recent, uploadedAt = recent)
        val oldTrimmed = reading(old, trimmedAt = old)
        val oldDropped = reading(old, dropped = true)
        val oldPending = reading(old)
        val failedBatch = UUID.randomUUID()
        db.uploadBatchDao().insert(
            UploadBatchEntity(
                id = failedBatch,
                state = UploadBatchState.FAILED_PERMANENT,
                createdAt = old,
                lastAttemptAt = old,
            ),
        )
        val oldFailed = reading(old, batchId = failedBatch)
        dao.insertAll(listOf(oldUploaded, recentUploaded, oldTrimmed, oldDropped, oldPending, oldFailed))

        val oldSession = UUID.randomUUID()
        val openSession = UUID.randomUUID()
        db.driveSessionDao().insert(DriveSessionEntity(id = oldSession, startedAt = old, startLatitude = 44.6, startLongitude = -63.5))
        db.driveSessionDao().seal(oldSession, old, 44.7, -63.6)
        db.driveSessionDao().insert(DriveSessionEntity(id = openSession, startedAt = old, startLatitude = 44.6, startLongitude = -63.5))

        val submitted = PotholeActionCoordinator.manualReport(PotholeLocation(44.6, -63.5, 5.0), old)
            .copy(uploadState = PotholeActionUploadState.SUBMITTED.wireValue, lastAttemptAt = old)
        val queued = PotholeActionCoordinator.manualReport(PotholeLocation(44.6, -63.5, 5.0), old)
            .copy(uploadState = PotholeActionUploadState.PENDING_UPLOAD.wireValue)
        db.potholeActionDao().insert(submitted)
        db.potholeActionDao().insert(queued)

        db.deviceTokenDao().upsert(
            DeviceTokenEntity(
                id = UUID.randomUUID(),
                token = UUID.randomUUID().toString(),
                issuedAt = old,
                expiresAt = old.plus(Duration.ofDays(30)),
            ),
        )

        val result = LocalRetentionPruner(db).prune(now)

        assertEquals(4, result.readings)
        assertNull(dao.findById(oldUploaded.id))
        assertNull(dao.findById(oldTrimmed.id))
        assertNull(dao.findById(oldDropped.id))
        assertNull(dao.findById(oldFailed.id))
        assertNotNull(dao.findById(recentUploaded.id), "recent uploads are kept")
        assertNotNull(dao.findById(oldPending.id), "never prune data still waiting to upload")
        assertNull(db.uploadBatchDao().findById(failedBatch))
        assertNull(db.driveSessionDao().findById(oldSession))
        assertNotNull(db.driveSessionDao().findById(openSession), "unsealed sessions wait for the orphan sweep")
        assertNull(db.potholeActionDao().findById(submitted.id))
        assertNotNull(db.potholeActionDao().findById(queued.id))
        assertNull(db.deviceTokenDao().current())
        assertEquals(result.total, result.readings + result.batches + result.driveSessions +
            result.potholeActions + result.feedback + result.deviceTokens)
    }
}
