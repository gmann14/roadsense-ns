package ca.roadsense.ns.api

import java.time.Duration
import java.time.Instant

data class QueueReadingRecord(
    val id: String,
    val recordedAt: Instant,
    val uploadedAt: Instant?,
)

object RetentionPolicy {
    /** How long finished local records (uploaded readings, trimmed or
     *  privacy-dropped readings, sealed drives, terminal queue rows) stay on
     *  the device. Pending, never-uploaded data is not subject to it. */
    val LOCAL_RETENTION: Duration = Duration.ofDays(30)

    /** Records finished before this instant are eligible for pruning. */
    fun cutoff(now: Instant): Instant = now.minus(LOCAL_RETENTION)

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
