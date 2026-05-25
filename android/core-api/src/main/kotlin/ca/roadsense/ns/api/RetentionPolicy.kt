package ca.roadsense.ns.api

import java.time.Duration
import java.time.Instant

data class QueueReadingRecord(
    val id: String,
    val recordedAt: Instant,
    val uploadedAt: Instant?,
)

object RetentionPolicy {
    private val LOCAL_RETENTION = Duration.ofDays(30)

    fun pruneUploadedReadings(
        readings: List<QueueReadingRecord>,
        now: Instant,
    ): List<QueueReadingRecord> {
        val cutoff = now.minus(LOCAL_RETENTION)
        return readings.filter { reading ->
            val uploaded = reading.uploadedAt ?: return@filter true
            !uploaded.isBefore(cutoff)
        }
    }
}
