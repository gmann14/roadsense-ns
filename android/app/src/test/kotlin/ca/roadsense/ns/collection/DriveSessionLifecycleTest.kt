package ca.roadsense.ns.collection

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.data.room.DriveSessionEntity
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.sensor.LocationSample
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
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
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The orphan sweep, the live-session guard and the wipe guard
 * (2026-10-18 review P0-2 / P0-3).
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class DriveSessionLifecycleTest {
    private lateinit var db: RoadSenseDatabase
    private lateinit var lifecycle: DriveSessionLifecycle
    private val now = Instant.parse("2026-05-01T00:00:00Z")

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            RoadSenseDatabase::class.java,
        ).allowMainThreadQueries().build()
        lifecycle = DriveSessionLifecycle(
            driveSessionDao = db.driveSessionDao(),
            readingDao = db.readingDao(),
            sealer = DriveSessionSealer(
                database = db,
                driveSessionDao = db.driveSessionDao(),
                readingDao = db.readingDao(),
                clock = { now },
            ),
        )
    }

    @After
    fun tearDown() = db.close()

    private val start = LocationSample(
        timestamp = now.epochSecond.toDouble(),
        latitude = 44.6488,
        longitude = -63.5752,
        horizontalAccuracyMeters = 5.0,
        speedKmh = 40.0,
        headingDegrees = 0.0,
    )

    private fun reading(sessionId: UUID?, secondsIntoDrive: Long, lat: Double = 44.68) = ReadingEntity(
        id = UUID.randomUUID(),
        latitude = lat,
        longitude = -63.60,
        roughnessRMS = 0.5,
        speedKMH = 50.0,
        heading = 90.0,
        gpsAccuracyM = 5.0,
        isPothole = false,
        potholeMagnitude = null,
        recordedAt = now.plusSeconds(secondsIntoDrive),
        driveSessionId = sessionId,
    )

    @Test
    fun `orphaned sessions from a previous run are sealed and their readings become eligible`() = runTest {
        val orphan = UUID.randomUUID()
        db.driveSessionDao().insert(
            DriveSessionEntity(id = orphan, startedAt = now, startLatitude = 44.6488, startLongitude = -63.5752),
        )
        val mid = reading(orphan, 300)
        db.readingDao().insert(mid)
        db.readingDao().insert(reading(orphan, 600, lat = 44.70))

        val sealed = lifecycle.finalizeOrphans()

        assertEquals(listOf(orphan), sealed.map { it.sessionId })
        assertTrue(db.driveSessionDao().findById(orphan)!!.isSealed)
        assertEquals(listOf(mid.id), db.readingDao().pendingForUpload(100).map { it.id })
        assertTrue(lifecycle.finalizeOrphans().isEmpty(), "second sweep has nothing to do")
    }

    @Test
    fun `the orphan sweep never seals a session a running pipeline owns`() = runTest {
        val live = lifecycle.openSession(start)

        assertTrue(lifecycle.finalizeOrphans().isEmpty())
        assertFalse(db.driveSessionDao().findById(live)!!.isSealed)
        assertTrue(lifecycle.recordReading(reading(live, 120)))
    }

    @Test
    fun `a reading without a session or for a sealed session is never written`() = runTest {
        assertFalse(lifecycle.recordReading(reading(sessionId = null, secondsIntoDrive = 10)))

        val session = lifecycle.openSession(start)
        lifecycle.sealSession(session, lastFix = null)
        assertFalse(lifecycle.recordReading(reading(session, 30)))

        assertEquals(0, db.readingDao().pendingCount())
    }

    @Test
    fun `after a wipe a live pipeline cannot write into the emptied database`() = runTest {
        val session = lifecycle.openSession(start)
        assertTrue(lifecycle.recordReading(reading(session, 120)))

        lifecycle.wipeLocalData {
            db.readingDao().deleteAll()
            db.driveSessionDao().deleteAll()
        }

        assertFalse(lifecycle.recordReading(reading(session, 180)))
        assertTrue(db.readingDao().byDriveSession(session).isEmpty())
        assertNull(db.driveSessionDao().findById(session))
    }

    @Test
    fun `concurrent opens create distinct sessions and every reading lands in one`() = runTest {
        val ids = (1..5).map { async { lifecycle.openSession(start) } }.awaitAll()
        assertEquals(5, ids.toSet().size)
        ids.forEach { assertTrue(lifecycle.recordReading(reading(it, 120))) }
        assertTrue(db.readingDao().pendingForUpload(100).isEmpty(), "nothing uploads before sealing")
    }
}
