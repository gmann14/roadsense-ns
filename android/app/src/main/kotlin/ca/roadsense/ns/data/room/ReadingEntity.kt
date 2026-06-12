package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

/**
 * Mirror of iOS `ReadingRecord`. Fields and semantics match line-for-line so
 * the cross-platform invariants (privacy filtering, endpoint trimming,
 * upload-ready gating) hold the same way on both clients.
 *
 * Indexes:
 * - `recorded_at` — used by retention pruning + ordering for upload batches
 * - `upload_batch_id` — every upload-drain cycle queries by batch id
 * - `drive_session_id` — drive-end UI walks readings by session
 */
@Entity(
    tableName = "readings",
    indices = [
        Index("recorded_at"),
        Index("upload_batch_id"),
        Index("drive_session_id"),
        Index(value = ["uploaded_at"]),
    ],
)
data class ReadingEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: UUID,

    @ColumnInfo(name = "latitude") val latitude: Double,
    @ColumnInfo(name = "longitude") val longitude: Double,
    @ColumnInfo(name = "roughness_rms") val roughnessRMS: Double,
    @ColumnInfo(name = "speed_kmh") val speedKMH: Double,
    @ColumnInfo(name = "heading") val heading: Double,
    @ColumnInfo(name = "gps_accuracy_m") val gpsAccuracyM: Double,
    @ColumnInfo(name = "is_pothole") val isPothole: Boolean,
    @ColumnInfo(name = "pothole_magnitude") val potholeMagnitude: Double?,
    @ColumnInfo(name = "recorded_at") val recordedAt: Instant,

    @ColumnInfo(name = "drive_session_id") val driveSessionId: UUID? = null,
    @ColumnInfo(name = "upload_batch_id") val uploadBatchId: UUID? = null,
    @ColumnInfo(name = "uploaded_at") val uploadedAt: Instant? = null,
    @ColumnInfo(name = "upload_ready_at") val uploadReadyAt: Instant? = null,
    @ColumnInfo(name = "endpoint_trimmed_at") val endpointTrimmedAt: Instant? = null,
    @ColumnInfo(name = "dropped_by_privacy_zone") val droppedByPrivacyZone: Boolean = false,
) {
    /**
     * Mirror of iOS `ReadingRecord.isReadyForUpload` — privacy-zone-dropped
     * and endpoint-trimmed readings never upload, and a reading attached to
     * a drive session waits until the session is sealed (`uploadReadyAt`).
     */
    val isReadyForUpload: Boolean
        get() = !droppedByPrivacyZone &&
            uploadedAt == null &&
            endpointTrimmedAt == null &&
            (driveSessionId == null || uploadReadyAt != null)
}
