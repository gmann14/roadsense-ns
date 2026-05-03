package ca.roadsense.ns.collection

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
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
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * End-to-end test of the on-device collection pipeline. Drives the real
 * Room schema with the same iOS CSV fixture used by the parity tests in
 * core-sensor — confirms that running the pipeline through the Android
 * `ReadingDao` produces the same window count + pothole flag as the iOS
 * harness does.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class CollectionPipelineTest {
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

    @Test
    fun `pothole-hit fixture replayed through Room emits one flagged reading`() = runTest {
        val csv = readResource("/pothole-hit.csv")
        val fixture = SensorFixtureParser.parse(csv)
        val pipeline = CollectionPipeline(readingDao = db.readingDao())

        replay(pipeline, fixture)

        val rows = db.readingDao().pendingForUpload(limit = 100)
        assertEquals(1, rows.size, "exactly one window should have been emitted")
        assertTrue(rows.first().isPothole, "the pothole-hit fixture should flag pothole=true")
    }

    @Test
    fun `privacy zone fixture filters out the in-zone GPS sample`() = runTest {
        val csv = readResource("/privacy-zone-recovery.csv")
        val fixture = SensorFixtureParser.parse(csv)
        val pipeline = CollectionPipeline(
            readingDao = db.readingDao(),
            privacyZones = listOf(
                PrivacyZone(latitude = 44.6488, longitude = -63.5752, radiusMeters = 250.0)
            ),
        )

        replay(pipeline, fixture)

        // After privacy-zone filtering we expect one accepted window from the
        // post-zone GPS samples — same as the iOS expected envelope.
        val rows = db.readingDao().pendingForUpload(limit = 100)
        assertEquals(1, rows.size)
        assertTrue(!rows.first().isPothole)
    }

    private suspend fun replay(pipeline: CollectionPipeline, fixture: SensorFixture) {
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
                            timestamp = event.timestampEpochSeconds,
                            userAcceleration = event.userAcceleration,
                            gravity = latestGravity,
                        )
                    )
                }
                is SensorFixtureEvent.Gps -> {
                    if (!isAutomotive) continue
                    pipeline.ingestLocation(event.sample as LocationSample)
                }
            }
        }
    }

    private fun readResource(path: String): String {
        val url = CollectionPipelineTest::class.java.getResource(path)
            ?: error("missing resource $path")
        return url.readText()
    }
}
