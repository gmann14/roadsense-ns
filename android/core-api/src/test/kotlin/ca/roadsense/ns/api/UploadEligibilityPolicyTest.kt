package ca.roadsense.ns.api

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UploadEligibilityPolicyTest {
    private val online = NetworkPathSnapshot(NetworkPathStatus.SATISFIED, isExpensive = false)
    private val offline = NetworkPathSnapshot(NetworkPathStatus.UNSATISFIED, isExpensive = false)

    @Test
    fun `uploads when online with pending and no backoff`() {
        assertTrue(UploadEligibilityPolicy.shouldUpload(pendingCount = 3, network = online))
    }

    @Test
    fun `does not upload when offline`() {
        assertFalse(UploadEligibilityPolicy.shouldUpload(pendingCount = 3, network = offline))
    }

    @Test
    fun `does not upload when nothing pending`() {
        assertFalse(UploadEligibilityPolicy.shouldUpload(pendingCount = 0, network = online))
    }

    @Test
    fun `respects future nextAttemptAt`() {
        val now = Instant.parse("2026-05-01T00:00:00Z")
        val future = now.plusSeconds(60)
        assertFalse(
            UploadEligibilityPolicy.shouldUpload(
                pendingCount = 5,
                network = online,
                nextAttemptAt = future,
                now = now,
            )
        )
    }

    @Test
    fun `allows upload when nextAttemptAt has passed`() {
        val now = Instant.parse("2026-05-01T00:00:00Z")
        val past = now.minusSeconds(60)
        assertTrue(
            UploadEligibilityPolicy.shouldUpload(
                pendingCount = 5,
                network = online,
                nextAttemptAt = past,
                now = now,
            )
        )
    }
}
