package ca.roadsense.ns.api

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals

class RetentionPolicyTest {
    private val now = Instant.parse("2026-05-01T00:00:00Z")

    @Test
    fun `keeps unuploaded readings regardless of age`() {
        val ancient = QueueReadingRecord(
            id = "a",
            recordedAt = now.minusSeconds(60L * 60 * 24 * 365),
            uploadedAt = null,
        )
        val pruned = RetentionPolicy.pruneUploadedReadings(listOf(ancient), now)
        assertEquals(listOf(ancient), pruned)
    }

    @Test
    fun `prunes uploaded readings older than 30 days`() {
        val old = QueueReadingRecord(
            id = "old",
            recordedAt = now.minusSeconds(60L * 60 * 24 * 60),
            uploadedAt = now.minusSeconds(60L * 60 * 24 * 31),
        )
        val recent = QueueReadingRecord(
            id = "recent",
            recordedAt = now.minusSeconds(60L * 60 * 24 * 5),
            uploadedAt = now.minusSeconds(60L * 60 * 24 * 5),
        )
        val pruned = RetentionPolicy.pruneUploadedReadings(listOf(old, recent), now)
        assertEquals(listOf(recent), pruned)
    }

    @Test
    fun `keeps uploaded readings exactly at the boundary`() {
        val boundary = QueueReadingRecord(
            id = "boundary",
            recordedAt = now.minusSeconds(60L * 60 * 24 * 30),
            uploadedAt = now.minusSeconds(60L * 60 * 24 * 30),
        )
        val pruned = RetentionPolicy.pruneUploadedReadings(listOf(boundary), now)
        assertEquals(listOf(boundary), pruned)
    }
}
