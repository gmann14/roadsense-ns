package ca.roadsense.ns.collection

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.MotionSample
import ca.roadsense.ns.sensor.MotionVector3
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.SensorFixture
import ca.roadsense.ns.sensor.SensorFixtureEvent
import ca.roadsense.ns.sensor.SensorFixtureParser
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * End-to-end test of the on-device collection pipeline. Drives the real
 * Room schema (through [DriveSessionLifecycle]) with the same iOS CSV
 * fixtures used by the parity tests in core-sensor, plus synthetic GPS
 * traces for the session rules: start, auto-end, live privacy zones.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class CollectionPipelineTest {
    private lateinit var db: RoadSenseDatabase
    private lateinit var lifecycle: DriveSessionLifecycle

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            RoadSenseDatabase::class.java,
        )
            .allowMainThreadQueries()
            .build()
        lifecycle = DriveSessionLifecycle(
            driveSessionDao = db.driveSessionDao(),
            readingDao = db.readingDao(),
            sealer = DriveSessionSealer(
                database = db,
                driveSessionDao = db.driveSessionDao(),
                readingDao = db.readingDao(),
            ),
        )
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun `pothole-hit fixture replayed through Room emits one flagged reading in a session`() = runTest {
        val pipeline = CollectionPipeline(sessions = lifecycle, privacyZones = emptyList())

        replay(pipeline, fixture("/pothole-hit.csv"))

        val sessionId = assertNotNull(pipeline.currentDriveSession())
        val rows = db.readingDao().byDriveSession(sessionId)
        assertEquals(1, rows.size, "exactly one window should have been emitted")
        assertTrue(rows.first().isPothole, "the pothole-hit fixture should flag pothole=true")
        assertTrue(
            db.readingDao().pendingForUpload(limit = 100).isEmpty(),
            "readings of an unsealed drive must not upload",
        )
    }

    @Test
    fun `privacy zone fixture filters out the in-zone GPS sample`() = runTest {
        val pipeline = CollectionPipeline(
            sessions = lifecycle,
            privacyZones = listOf(
                PrivacyZone(latitude = 44.6488, longitude = -63.5752, radiusMeters = 250.0),
            ),
        )

        replay(pipeline, fixture("/privacy-zone-recovery.csv"))

        // One accepted window from the post-zone GPS samples — same as the
        // iOS expected envelope — and the session starts outside the zone.
        val sessionId = assertNotNull(pipeline.currentDriveSession())
        val rows = db.readingDao().byDriveSession(sessionId)
        assertEquals(1, rows.size)
        assertTrue(!rows.first().isPothole)
        val session = db.driveSessionDao().findById(sessionId)!!
        assertEquals(44.6515, session.startLatitude, 1e-6)
    }

    @Test
    fun `nothing is persisted before privacy zones are loaded`() = runTest {
        val pipeline = CollectionPipeline(sessions = lifecycle, privacyZones = null)

        replay(pipeline, fixture("/pothole-hit.csv"))

        assertNull(pipeline.currentDriveSession())
        assertTrue(db.driveSessionDao().recent(10).isEmpty())
        assertEquals(0, db.readingDao().pendingCount())
    }

    @Test
    fun `every persisted reading carries a drive session and Stop seals it`() = runTest {
        var sealedCount = 0
        val pipeline = CollectionPipeline(
            sessions = lifecycle,
            privacyZones = emptyList(),
            onDriveSealed = { sealedCount++ },
        )
        replay(pipeline, fixture("/pothole-hit.csv"))
        val sessionId = assertNotNull(pipeline.currentDriveSession())

        pipeline.endDrive()
        pipeline.endDrive() // idempotent

        assertNull(pipeline.currentDriveSession())
        assertEquals(1, sealedCount)
        assertTrue(db.driveSessionDao().findById(sessionId)!!.isSealed)
        val all = db.readingDao().byDriveSession(sessionId)
        assertTrue(all.isNotEmpty())
        assertTrue(all.all { it.driveSessionId == sessionId })
        // A 4-second drive is entirely inside the endpoint trim window.
        assertTrue(all.all { it.endpointTrimmedAt != null })
    }

    @Test
    fun `a session does not start on an inaccurate or stationary fix`() = runTest {
        val gateway = FakeGateway()
        val pipeline = CollectionPipeline(sessions = gateway, privacyZones = emptyList())

        pipeline.ingestLocation(fix(t = 0.0, lat = 44.70, speedKmh = 50.0, accuracy = 35.0))
        pipeline.ingestLocation(fix(t = 1.0, lat = 44.70, speedKmh = 0.0))
        assertNull(pipeline.currentDriveSession())

        pipeline.ingestLocation(fix(t = 2.0, lat = 44.70, speedKmh = 40.0, accuracy = 8.0))
        assertNotNull(pipeline.currentDriveSession())
        assertEquals(1, gateway.opened.size)
    }

    @Test
    fun `five minutes parked seals the drive and the next movement opens a new one`() = runTest {
        val gateway = FakeGateway()
        var sealedCount = 0
        val pipeline = CollectionPipeline(
            sessions = gateway,
            privacyZones = emptyList(),
            onDriveSealed = { sealedCount++ },
        )
        // Drive north at ~54 km/h for 60 s.
        var t = 1_000.0
        var lat = 44.70
        repeat(60) {
            pipeline.ingestLocation(fix(t = t, lat = lat, speedKmh = 54.0))
            t += 1.0
            lat += 0.000135
        }
        val first = assertNotNull(pipeline.currentDriveSession())

        // Parked: jittery fixes at walking-pace noise for 4 min — still the same drive.
        repeat(8) {
            pipeline.ingestLocation(fix(t = t, lat = lat + 0.00002, speedKmh = 1.0))
            t += 30.0
        }
        assertEquals(first, pipeline.currentDriveSession())
        assertTrue(!pipeline.checkAutoEnd(t))

        // No fixes at all (distance filter) — the periodic tick ends it.
        assertTrue(pipeline.checkAutoEnd(t + 120.0))
        assertNull(pipeline.currentDriveSession())
        assertEquals(listOf(first), gateway.sealed)
        assertEquals(1, sealedCount)
        // The seal uses the last fix, where the car is parked.
        assertEquals(lat + 0.00002, gateway.sealFixes.single()!!.latitude, 1e-9)

        // Driving again opens a second session.
        t += 600.0
        pipeline.ingestLocation(fix(t = t, lat = lat, speedKmh = 30.0))
        val second = assertNotNull(pipeline.currentDriveSession())
        assertTrue(second != first)
        assertEquals(2, gateway.opened.size)
    }

    @Test
    fun `the first fix after a long silent stop ends the old drive`() = runTest {
        val gateway = FakeGateway()
        val pipeline = CollectionPipeline(sessions = gateway, privacyZones = emptyList())
        pipeline.ingestLocation(fix(t = 0.0, lat = 44.70, speedKmh = 50.0))
        val first = assertNotNull(pipeline.currentDriveSession())

        // Ten minutes later, no tick ran (e.g. the process was dozing) and
        // the car pulls away.
        pipeline.ingestLocation(fix(t = 600.0, lat = 44.70, speedKmh = 40.0))

        assertEquals(listOf(first), gateway.sealed)
        val second = assertNotNull(pipeline.currentDriveSession())
        assertTrue(second != first)
    }

    @Test
    fun `a zone added mid-drive applies to the next fix`() = runTest {
        val pipeline = CollectionPipeline(sessions = lifecycle, privacyZones = emptyList())
        replay(pipeline, fixture("/pothole-hit.csv"))
        val sessionId = assertNotNull(pipeline.currentDriveSession())
        val before = db.readingDao().byDriveSession(sessionId).size

        pipeline.setPrivacyZones(
            listOf(PrivacyZone(latitude = 44.6500, longitude = -63.5752, radiusMeters = 500.0)),
        )
        replay(pipeline, fixture("/pothole-hit.csv"), timeOffsetSeconds = 10.0)

        assertEquals(before, db.readingDao().byDriveSession(sessionId).size, "no reading inside the new zone")
    }

    @Test
    fun `after a local wipe the pipeline stops writing and starts a fresh session`() = runTest {
        val pipeline = CollectionPipeline(sessions = lifecycle, privacyZones = emptyList())
        replay(pipeline, fixture("/pothole-hit.csv"))
        val first = assertNotNull(pipeline.currentDriveSession())

        lifecycle.wipeLocalData {
            db.readingDao().deleteAll()
            db.driveSessionDao().deleteAll()
        }
        replay(pipeline, fixture("/pothole-hit.csv"), timeOffsetSeconds = 10.0)

        assertTrue(db.readingDao().byDriveSession(first).isEmpty(), "nothing written into the wiped session")
        assertNull(db.driveSessionDao().findById(first))
    }

    private fun fix(
        t: Double,
        lat: Double,
        speedKmh: Double,
        accuracy: Double = 5.0,
        lng: Double = -63.60,
    ) = LocationSample(
        timestamp = t,
        latitude = lat,
        longitude = lng,
        horizontalAccuracyMeters = accuracy,
        speedKmh = speedKmh,
        headingDegrees = 0.0,
    )

    private class FakeGateway : DriveSessionGateway {
        val opened = mutableListOf<UUID>()
        val sealed = mutableListOf<UUID>()
        val sealFixes = mutableListOf<LocationSample?>()
        val readings = mutableListOf<ReadingEntity>()

        override suspend fun openSession(start: LocationSample): UUID =
            UUID.randomUUID().also { opened += it }

        override suspend fun recordReading(reading: ReadingEntity): Boolean {
            readings += reading
            return true
        }

        override suspend fun sealSession(sessionId: UUID, lastFix: LocationSample?) {
            sealed += sessionId
            sealFixes += lastFix
        }
    }

    private suspend fun replay(
        pipeline: CollectionPipeline,
        fixture: SensorFixture,
        timeOffsetSeconds: Double = 0.0,
    ) {
        var isAutomotive = false
        var latestGravity = MotionVector3(0.0, 0.0, 1.0)
        for (event in fixture.events) {
            when (event) {
                is SensorFixtureEvent.Activity -> isAutomotive = event.isAutomotive
                is SensorFixtureEvent.Gravity -> latestGravity = event.gravity
                is SensorFixtureEvent.Thermal -> { /* default */ }
                is SensorFixtureEvent.Accel -> {
                    if (!isAutomotive) continue
                    pipeline.ingestMotion(
                        MotionSample(
                            timestamp = event.timestampEpochSeconds + timeOffsetSeconds,
                            userAcceleration = event.userAcceleration,
                            gravity = latestGravity,
                        ),
                    )
                }
                is SensorFixtureEvent.Gps -> {
                    if (!isAutomotive) continue
                    val sample = event.sample as LocationSample
                    pipeline.ingestLocation(sample.copy(timestamp = sample.timestamp + timeOffsetSeconds))
                }
            }
        }
    }

    private fun fixture(path: String): SensorFixture {
        val url = CollectionPipelineTest::class.java.getResource(path)
            ?: error("missing resource $path")
        return SensorFixtureParser.parse(url.readText())
    }
}
