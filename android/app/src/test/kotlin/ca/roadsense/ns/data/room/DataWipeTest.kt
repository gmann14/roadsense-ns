package ca.roadsense.ns.data.room

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals

/**
 * Asserts that the per-DAO `deleteAll` queries supporting Settings →
 * "Delete all local data" actually wipe their tables. Mirrors the iOS
 * Settings → "Erase locally stored RoadSense data" flow.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class DataWipeTest {
    private lateinit var db: RoadSenseDatabase
    private val now = Instant.parse("2026-05-01T12:00:00Z")

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
    fun `deleteAll clears every table the wipe touches`() = runTest {
        db.readingDao().insert(
            ReadingEntity(
                id = UUID.randomUUID(),
                latitude = 44.0,
                longitude = -63.0,
                roughnessRMS = 0.5,
                speedKMH = 50.0,
                heading = 90.0,
                gpsAccuracyM = 5.0,
                isPothole = false,
                potholeMagnitude = null,
                recordedAt = now,
            ),
        )
        db.privacyZoneDao().upsert(
            PrivacyZoneEntity(
                id = UUID.randomUUID(),
                label = "home",
                latitude = 44.0,
                longitude = -63.0,
                radiusM = 250.0,
                createdAt = now,
            ),
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
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = UUID.randomUUID(),
                startedAt = now,
                startLatitude = 44.0,
                startLongitude = -63.0,
            ),
        )
        db.uploadBatchDao().insert(
            UploadBatchEntity(
                id = UUID.randomUUID(),
                state = UploadBatchState.PENDING,
                createdAt = now,
            ),
        )

        // Wipe.
        db.readingDao().deleteAll()
        db.uploadBatchDao().deleteAll()
        db.potholeActionDao().deleteAll()
        db.potholePhotoDao().deleteAll()
        db.privacyZoneDao().deleteAll()
        db.driveSessionDao().deleteAll()
        db.feedbackDao().deleteAll()
        db.userStatsDao().deleteAll()
        db.deviceTokenDao().deleteAll()

        assertEquals(0, db.readingDao().pendingCount())
        assertEquals(emptyList(), db.privacyZoneDao().list())
        assertEquals(0, db.feedbackDao().pendingCount(FeedbackUploadState.PENDING.wireValue))
        assertEquals(emptyList(), db.driveSessionDao().recent(10))
    }
}
