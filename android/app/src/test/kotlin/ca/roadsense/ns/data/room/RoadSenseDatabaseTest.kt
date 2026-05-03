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
import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class RoadSenseDatabaseTest {
    private lateinit var db: RoadSenseDatabase

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

    private val now: Instant = Instant.parse("2026-05-01T12:00:00Z")

    private fun reading(
        id: UUID = UUID.randomUUID(),
        recordedAt: Instant = now,
        droppedByPrivacyZone: Boolean = false,
        endpointTrimmedAt: Instant? = null,
        uploadedAt: Instant? = null,
        driveSessionId: UUID? = null,
        uploadReadyAt: Instant? = null,
    ) = ReadingEntity(
        id = id,
        latitude = 44.6488,
        longitude = -63.5752,
        roughnessRMS = 0.5,
        speedKMH = 50.0,
        heading = 90.0,
        gpsAccuracyM = 5.0,
        isPothole = false,
        potholeMagnitude = null,
        recordedAt = recordedAt,
        driveSessionId = driveSessionId,
        uploadedAt = uploadedAt,
        uploadReadyAt = uploadReadyAt,
        endpointTrimmedAt = endpointTrimmedAt,
        droppedByPrivacyZone = droppedByPrivacyZone,
    )

    @Test
    fun `insert and read a reading round-trips`() = runTest {
        val sample = reading()
        db.readingDao().insert(sample)

        val fetched = db.readingDao().findById(sample.id)
        assertNotNull(fetched)
        assertEquals(sample, fetched)
    }

    @Test
    fun `pendingForUpload excludes privacy-zone-dropped readings`() = runTest {
        val ready = reading()
        val dropped = reading(droppedByPrivacyZone = true)
        db.readingDao().insertAll(listOf(ready, dropped))

        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertEquals(listOf(ready.id), pending.map { it.id })
    }

    @Test
    fun `pendingForUpload excludes endpoint-trimmed readings`() = runTest {
        val ready = reading()
        val trimmed = reading(endpointTrimmedAt = now)
        db.readingDao().insertAll(listOf(ready, trimmed))

        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertEquals(listOf(ready.id), pending.map { it.id })
    }

    @Test
    fun `pendingForUpload excludes already-uploaded readings`() = runTest {
        val ready = reading()
        val uploaded = reading(uploadedAt = now)
        db.readingDao().insertAll(listOf(ready, uploaded))

        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertEquals(listOf(ready.id), pending.map { it.id })
    }

    @Test
    fun `pendingForUpload excludes drive-attached readings until session sealed`() = runTest {
        val sessionId = UUID.randomUUID()
        val unsealedReading = reading(driveSessionId = sessionId, uploadReadyAt = null)
        val sealedReading = reading(driveSessionId = sessionId, uploadReadyAt = now)
        val unattached = reading()
        db.readingDao().insertAll(listOf(unsealedReading, sealedReading, unattached))

        val pending = db.readingDao().pendingForUpload(limit = 100).map { it.id }.toSet()
        assertTrue(unsealedReading.id !in pending)
        assertTrue(sealedReading.id in pending)
        assertTrue(unattached.id in pending)
    }

    @Test
    fun `assignBatch and markBatchUploaded flips uploadedAt`() = runTest {
        val a = reading()
        val b = reading()
        db.readingDao().insertAll(listOf(a, b))

        val batchId = UUID.randomUUID()
        db.readingDao().assignBatch(listOf(a.id, b.id), batchId)
        db.readingDao().markBatchUploaded(batchId, now)

        assertNotNull(db.readingDao().findById(a.id)?.uploadedAt)
        assertNotNull(db.readingDao().findById(b.id)?.uploadedAt)
    }

    @Test
    fun `releaseBatch clears assignment for un-uploaded rows`() = runTest {
        val a = reading()
        db.readingDao().insertAll(listOf(a))

        val batchId = UUID.randomUUID()
        db.readingDao().assignBatch(listOf(a.id), batchId)
        db.readingDao().releaseBatch(batchId)

        val fetched = db.readingDao().findById(a.id)
        assertNull(fetched?.uploadBatchId)
    }

    @Test
    fun `pruneUploadedBefore deletes only uploaded rows older than cutoff`() = runTest {
        val recent = reading(uploadedAt = now.minus(Duration.ofDays(5)))
        val ancient = reading(uploadedAt = now.minus(Duration.ofDays(60)))
        val unuploaded = reading()
        db.readingDao().insertAll(listOf(recent, ancient, unuploaded))

        val cutoff = now.minus(Duration.ofDays(30))
        val deleted = db.readingDao().pruneUploadedBefore(cutoff)
        assertEquals(1, deleted)
        assertNotNull(db.readingDao().findById(recent.id))
        assertNull(db.readingDao().findById(ancient.id))
        assertNotNull(db.readingDao().findById(unuploaded.id))
    }

    @Test
    fun `privacy zone dao upsert and list round-trips`() = runTest {
        val zone = PrivacyZoneEntity(
            id = UUID.randomUUID(),
            label = "home",
            latitude = 44.65,
            longitude = -63.57,
            radiusM = 250.0,
            createdAt = now,
        )
        db.privacyZoneDao().upsert(zone)
        assertEquals(listOf(zone), db.privacyZoneDao().list())
    }

    @Test
    fun `drive session seal sets ended fields and is_sealed`() = runTest {
        val session = DriveSessionEntity(
            id = UUID.randomUUID(),
            startedAt = now,
            startLatitude = 44.65,
            startLongitude = -63.57,
        )
        db.driveSessionDao().insert(session)

        val endedAt = now.plus(Duration.ofMinutes(20))
        db.driveSessionDao().seal(session.id, endedAt, 44.66, -63.58)

        val sealed = db.driveSessionDao().findById(session.id)!!
        assertEquals(endedAt, sealed.endedAt)
        assertEquals(44.66, sealed.endLatitude)
        assertEquals(-63.58, sealed.endLongitude)
        assertTrue(sealed.isSealed)
    }
}
