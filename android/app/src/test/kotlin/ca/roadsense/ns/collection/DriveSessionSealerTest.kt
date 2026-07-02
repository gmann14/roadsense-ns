package ca.roadsense.ns.collection

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.data.room.DriveSessionEntity
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
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

    private fun sealer(clock: () -> Instant = { now }) = DriveSessionSealer(
        driveSessionDao = db.driveSessionDao(),
        readingDao = db.readingDao(),
        clock = clock,
    )

    private fun reading(
        id: UUID = UUID.randomUUID(),
        recordedAt: Instant,
        latitude: Double,
        longitude: Double,
        driveSessionId: UUID,
    ) = ReadingEntity(
        id = id,
        latitude = latitude,
        longitude = longitude,
        roughnessRMS = 0.5,
        speedKMH = 50.0,
        heading = 90.0,
        gpsAccuracyM = 5.0,
        isPothole = false,
        potholeMagnitude = null,
        recordedAt = recordedAt,
        driveSessionId = driveSessionId,
    )

    @Test
    fun `readings inside the first-minute window are trimmed and never upload-eligible`() = runTest {
        val sessionId = UUID.randomUUID()
        val start = now
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = sessionId,
                startedAt = start,
                startLatitude = 44.6488,
                startLongitude = -63.5752,
            ),
        )
        // 30s into the drive, near the start coordinate — should trim.
        val nearStart = reading(
            recordedAt = start.plusSeconds(30),
            latitude = 44.6488,
            longitude = -63.5752,
            driveSessionId = sessionId,
        )
        db.readingDao().insert(nearStart)

        sealer().sealAndTrim(
            driveSessionId = sessionId,
            endLatitude = 44.70,
            endLongitude = -63.62,
            endedAt = start.plusSeconds(600),
        )

        val stored = db.readingDao().findById(nearStart.id)!!
        assertNotNull(stored.endpointTrimmedAt, "reading inside the start trim window should be trimmed")
        assertNull(stored.uploadReadyAt)

        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertTrue(pending.none { it.id == nearStart.id }, "trimmed reading must never be upload-eligible")
    }

    @Test
    fun `mid-drive readings outside both endpoint zones become upload-ready`() = runTest {
        val sessionId = UUID.randomUUID()
        val start = now
        val end = start.plusSeconds(600)
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = sessionId,
                startedAt = start,
                startLatitude = 44.6488,
                startLongitude = -63.5752,
            ),
        )
        val midDrive = reading(
            recordedAt = start.plusSeconds(300),
            latitude = 44.68,
            longitude = -63.60,
            driveSessionId = sessionId,
        )
        db.readingDao().insert(midDrive)

        sealer().sealAndTrim(
            driveSessionId = sessionId,
            endLatitude = 44.70,
            endLongitude = -63.62,
            endedAt = end,
        )

        val stored = db.readingDao().findById(midDrive.id)!!
        assertNull(stored.endpointTrimmedAt)
        assertNotNull(stored.uploadReadyAt)

        val pending = db.readingDao().pendingForUpload(limit = 100)
        assertTrue(pending.any { it.id == midDrive.id }, "mid-drive reading should become upload-eligible once sealed")
    }

    @Test
    fun `readings near the end coordinate are trimmed even outside the time window`() = runTest {
        val sessionId = UUID.randomUUID()
        val start = now
        val end = start.plusSeconds(600)
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = sessionId,
                startedAt = start,
                startLatitude = 44.6488,
                startLongitude = -63.5752,
            ),
        )
        // Mid-drive by time, but sitting right on top of the end coordinate.
        val nearEnd = reading(
            recordedAt = start.plusSeconds(300),
            latitude = 44.70,
            longitude = -63.62,
            driveSessionId = sessionId,
        )
        db.readingDao().insert(nearEnd)

        sealer().sealAndTrim(
            driveSessionId = sessionId,
            endLatitude = 44.70,
            endLongitude = -63.62,
            endedAt = end,
        )

        val stored = db.readingDao().findById(nearEnd.id)!!
        assertNotNull(stored.endpointTrimmedAt)
        assertNull(stored.uploadReadyAt)
    }

    @Test
    fun `seals the session and records end coordinates`() = runTest {
        val sessionId = UUID.randomUUID()
        val start = now
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = sessionId,
                startedAt = start,
                startLatitude = 44.6488,
                startLongitude = -63.5752,
            ),
        )

        sealer().sealAndTrim(
            driveSessionId = sessionId,
            endLatitude = 44.70,
            endLongitude = -63.62,
            endedAt = start.plusSeconds(120),
        )

        val session = db.driveSessionDao().findById(sessionId)!!
        assertTrue(session.isSealed)
        assertEquals(44.70, session.endLatitude)
        assertEquals(-63.62, session.endLongitude)
    }

    @Test
    fun `falls back to the last reading coordinate when no end fix is available`() = runTest {
        val sessionId = UUID.randomUUID()
        val start = now
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = sessionId,
                startedAt = start,
                startLatitude = 44.6488,
                startLongitude = -63.5752,
            ),
        )
        val lastReading = reading(
            recordedAt = start.plusSeconds(500),
            latitude = 44.69,
            longitude = -63.61,
            driveSessionId = sessionId,
        )
        db.readingDao().insert(lastReading)

        sealer().sealAndTrim(
            driveSessionId = sessionId,
            endLatitude = null,
            endLongitude = null,
            endedAt = start.plusSeconds(600),
        )

        val session = db.driveSessionDao().findById(sessionId)!!
        assertEquals(lastReading.latitude, session.endLatitude)
        assertEquals(lastReading.longitude, session.endLongitude)
    }

    @Test
    fun `sealing an already-sealed session is a no-op`() = runTest {
        val sessionId = UUID.randomUUID()
        val start = now
        db.driveSessionDao().insert(
            DriveSessionEntity(
                id = sessionId,
                startedAt = start,
                startLatitude = 44.6488,
                startLongitude = -63.5752,
            ),
        )
        db.driveSessionDao().seal(sessionId, start.plusSeconds(600), 44.70, -63.62)

        // Should not throw and should not alter the already-sealed record.
        sealer().sealAndTrim(
            driveSessionId = sessionId,
            endLatitude = 1.0,
            endLongitude = 1.0,
            endedAt = start.plusSeconds(9_000),
        )

        val session = db.driveSessionDao().findById(sessionId)!!
        assertEquals(44.70, session.endLatitude)
        assertEquals(-63.62, session.endLongitude)
    }
}
