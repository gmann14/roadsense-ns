package ca.roadsense.ns.data

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import ca.roadsense.ns.data.room.DeviceTokenEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * P0-2 (2026-10-18 review): the server rejects any `device_token` that is not
 * a UUIDv4. These tests run real [DeviceTokenStore] output through the exact
 * regex the edge handlers use.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class DeviceTokenStoreTest {
    /**
     * Copied verbatim from `supabase/functions/upload-readings/handler.ts`
     * (`UUID_V4_REGEX`; `pothole-actions` and `pothole-photos` use the same
     * pattern). If the server regex changes, update this copy in the same PR.
     */
    private val serverUuidV4Regex =
        Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOption.IGNORE_CASE)

    private lateinit var db: RoadSenseDatabase
    private val now = Instant.parse("2026-11-01T12:00:00Z")

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
    fun `fresh token matches the server UUIDv4 regex`() = runTest {
        val store = DeviceTokenStore(db.deviceTokenDao())
        repeat(50) {
            db.deviceTokenDao().deleteAll()
            val token = store.currentToken(now)
            assertTrue(serverUuidV4Regex.matches(token), "token '$token' must satisfy the server regex")
        }
    }

    @Test
    fun `token is stable until it expires`() = runTest {
        val store = DeviceTokenStore(db.deviceTokenDao())
        val first = store.currentToken(now)
        val second = store.currentToken(now.plus(29, ChronoUnit.DAYS))
        assertEquals(first, second)

        val rotated = store.currentToken(now.plus(31, ChronoUnit.DAYS))
        assertNotEquals(first, rotated)
        assertTrue(serverUuidV4Regex.matches(rotated))
    }

    @Test
    fun `legacy base64url token is replaced with a UUIDv4`() = runTest {
        val legacy = "q3J0dGVzdC10b2tlbi1mcm9tLWJ1aWxkLTAuMS4wLWFiY2RlZmc"
        db.deviceTokenDao().upsert(
            DeviceTokenEntity(
                id = UUID.randomUUID(),
                token = legacy,
                issuedAt = now.minus(1, ChronoUnit.DAYS),
                expiresAt = now.plus(20, ChronoUnit.DAYS),
            ),
        )

        val token = DeviceTokenStore(db.deviceTokenDao()).currentToken(now)

        assertNotEquals(legacy, token)
        assertTrue(serverUuidV4Regex.matches(token))
        assertEquals(token, db.deviceTokenDao().current()?.token, "the migrated token must be persisted")
        assertEquals(token, DeviceTokenStore(db.deviceTokenDao()).currentToken(now), "and reused afterwards")
    }
}
