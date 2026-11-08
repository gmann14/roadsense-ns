package ca.roadsense.ns.collection

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.data.room.DriveSessionEntity
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.PrivacyZone
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
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Covers the privacy-critical piece of drive-endpoint trimming: sealing a
 * drive session applies `DriveEndpointTrimmer` to every reading recorded
 * during the drive, and only readings outside the trim window/radius ever
 * become upload-eligible.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class DriveSessionSealerTest {
    private lateinit var db: RoadSenseDatabase
    private val now = Instant.parse("2026-05-01T00:00:00Z")
    private val startLat = 44.6488
    private val startLng = -63.5752

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

    private fun sealer(zones: List<PrivacyZone> = emptyList()) = DriveSessionSealer(
        database = db,
        driveSessionDao = db.driveSessionDao(),
        readingDao = db.readingDao(),
        privacyZones = { zones },
        clock = { now },
    )

    private suspend fun openSession(): UUID {
        val id = UUID.randomUUID()
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = id,
                startedAt = now,
                startLatitude = startLat,
                startLongitude = startLng,
            ),
        )
        return id
    }

    private fun reading(
        sessionId: UUID,
        secondsIntoDrive: Long,
        latitude: Double,
        longitude: Double,
    ) = ReadingEntity(
        id = UUID.randomUUID(),
        latitude = latitude,
        longitude = longitude,
        roughnessRMS = 0.5,
        speedKMH = 50.0,
        heading = 90.0,
        gpsAccuracyM = 5.0,
        isPothole = false,
        potholeMagnitude = null,
        recordedAt = now.plusSeconds(secondsIntoDrive),
        driveSessionId = sessionId,
    )

    private fun fix(secondsIntoDrive: Long, latitude: Double, longitude: Double) = LocationSample(
        timestamp = now.plusSeconds(secondsIntoDrive).toEpochMilli() / 1000.0,
        latitude = latitude,
        longitude = longitude,
        horizontalAccuracyMeters = 5.0,
        speedKmh = 0.0,
        headingDegrees = 0.0,
    )

    /** A reading far from both ends at [secondsIntoDrive] plus one later
     *  "arrival" reading so the mid-drive one is outside the end window. */
    private suspend fun insertDrive(sessionId: UUID, secondsIntoDrive: Long = 300): ReadingEntity {
        val mid = reading(sessionId, secondsIntoDrive, 44.68, -63.60)
        db.readingDao().insert(mid)
        db.readingDao().insert(reading(sessionId, 600, 44.70, -63.62))
        return mid
    }

    @Test
    fun `readings inside the first-minute window are trimmed and never upload-eligible`() = runTest {
        val sessionId = openSession()
        val nearStart = reading(sessionId, 30, startLat, startLng)
        db.readingDao().insert(nearStart)
        insertDrive(sessionId)

        sealer().sealAndTrim(sessionId, fix(600, 44.70, -63.62))

        val stored = db.readingDao().findById(nearStart.id)!!
        assertNotNull(stored.endpointTrimmedAt, "reading inside the start trim window should be trimmed")
        assertNull(stored.uploadReadyAt)
        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertTrue(pending.none { it.id == nearStart.id }, "trimmed reading must never be upload-eligible")
    }

    @Test
    fun `mid-drive readings outside both endpoint zones become upload-ready`() = runTest {
        val sessionId = openSession()
        val midDrive = insertDrive(sessionId)

        val summary = sealer().sealAndTrim(sessionId, fix(600, 44.70, -63.62))

        assertNotNull(summary)
        assertEquals(1, summary.eligibleReadingCount)
        val stored = db.readingDao().findById(midDrive.id)!!
        assertNull(stored.endpointTrimmedAt)
        assertNotNull(stored.uploadReadyAt)
        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertTrue(pending.any { it.id == midDrive.id }, "mid-drive reading should become upload-eligible once sealed")
    }

    @Test
    fun `readings near the end coordinate are trimmed even outside the time window`() = runTest {
        val sessionId = openSession()
        val nearEnd = reading(sessionId, 300, 44.70, -63.62)
        db.readingDao().insert(nearEnd)
        db.readingDao().insert(reading(sessionId, 600, 44.70, -63.62))

        sealer().sealAndTrim(sessionId, fix(600, 44.70, -63.62))

        val stored = db.readingDao().findById(nearEnd.id)!!
        assertNotNull(stored.endpointTrimmedAt)
        assertNull(stored.uploadReadyAt)
    }

    @Test
    fun `endedAt is the last reading time, not when Stop was tapped`() = runTest {
        val sessionId = openSession()
        insertDrive(sessionId)
        // The car parked at 600 s; Stop is tapped an hour later from the
        // same spot. The later fix supplies the end coordinate only.
        sealer().sealAndTrim(sessionId, fix(4_200, 44.70, -63.62))

        val session = db.driveSessionDao().findById(sessionId)!!
        assertTrue(session.isSealed)
        assertEquals(now.plusSeconds(600), session.endedAt)
        assertEquals(44.70, session.endLatitude)
        assertEquals(-63.62, session.endLongitude)
    }

    @Test
    fun `a fix older than the last reading does not become the end coordinate`() = runTest {
        val sessionId = openSession()
        insertDrive(sessionId)

        sealer().sealAndTrim(sessionId, fix(100, 1.0, 1.0))

        val session = db.driveSessionDao().findById(sessionId)!!
        assertEquals(44.70, session.endLatitude)
        assertEquals(-63.62, session.endLongitude)
    }

    @Test
    fun `falls back to the last reading coordinate when no end fix is available`() = runTest {
        val sessionId = openSession()
        insertDrive(sessionId)

        sealer().sealAndTrim(sessionId, lastFix = null)

        val session = db.driveSessionDao().findById(sessionId)!!
        assertEquals(44.70, session.endLatitude)
        assertEquals(-63.62, session.endLongitude)
        assertEquals(now.plusSeconds(600), session.endedAt)
    }

    @Test
    fun `an empty session seals at its start`() = runTest {
        val sessionId = openSession()

        val summary = sealer().sealAndTrim(sessionId, lastFix = null)

        assertNotNull(summary)
        val session = db.driveSessionDao().findById(sessionId)!!
        assertTrue(session.isSealed)
        assertEquals(now, session.endedAt)
        assertEquals(startLat, session.endLatitude)
    }

    @Test
    fun `sealing twice is a no-op the second time`() = runTest {
        val sessionId = openSession()
        val midDrive = insertDrive(sessionId)
        assertNotNull(sealer().sealAndTrim(sessionId, fix(600, 44.70, -63.62)))
        val firstReadyAt = db.readingDao().findById(midDrive.id)!!.uploadReadyAt

        val second = sealer().sealAndTrim(sessionId, fix(9_000, 1.0, 1.0))

        assertNull(second)
        val session = db.driveSessionDao().findById(sessionId)!!
        assertEquals(44.70, session.endLatitude)
        assertEquals(firstReadyAt, db.readingDao().findById(midDrive.id)!!.uploadReadyAt)
    }

    @Test
    fun `an unknown session returns null`() = runTest {
        assertNull(sealer().sealAndTrim(UUID.randomUUID(), lastFix = null))
    }

    @Test
    fun `privacy zones are re-applied at seal time`() = runTest {
        val sessionId = openSession()
        val midDrive = insertDrive(sessionId)
        val zone = PrivacyZone(latitude = 44.68, longitude = -63.60, radiusMeters = 250.0)

        val summary = sealer(listOf(zone)).sealAndTrim(sessionId, fix(600, 44.70, -63.62))

        assertNotNull(summary)
        assertEquals(1, summary.privacyDroppedReadingCount)
        val stored = db.readingDao().findById(midDrive.id)!!
        assertTrue(stored.droppedByPrivacyZone)
        assertNull(stored.uploadReadyAt)
        assertTrue(db.readingDao().pendingForUpload(limit = 100).isEmpty())
    }
}
