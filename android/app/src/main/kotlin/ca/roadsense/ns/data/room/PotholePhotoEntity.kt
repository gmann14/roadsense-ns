package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

enum class PhotoUploadState(val wireValue: String) {
    PENDING_METADATA("pending_metadata"),
    PENDING_MODERATION("pending_moderation"),
    FAILED_PERMANENT("failed_permanent");

    companion object {
        fun fromWire(value: String): PhotoUploadState =
            entries.firstOrNull { it.wireValue == value } ?: PENDING_METADATA
    }
}

/**
 * Mirror of iOS `PotholeReportRecord`. Photo bytes live on app-internal
 * storage (`photo_file_path`), not in Room — Room holds only metadata so
 * SQLite stays small and the photo can be deleted independently of the row
 * when retention prunes it.
 */
@Entity(
    tableName = "pothole_photos",
    indices = [Index("upload_state"), Index("next_attempt_at")],
)
data class PotholePhotoEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "segment_id") val segmentId: UUID? = null,
    @ColumnInfo(name = "photo_file_path") val photoFilePath: String,
    @ColumnInfo(name = "latitude") val latitude: Double,
    @ColumnInfo(name = "longitude") val longitude: Double,
    @ColumnInfo(name = "accuracy_m") val accuracyM: Double,
    @ColumnInfo(name = "captured_at") val capturedAt: Instant,
    @ColumnInfo(name = "upload_state") val uploadState: String,
    @ColumnInfo(name = "upload_attempt_count") val uploadAttemptCount: Int = 0,
    @ColumnInfo(name = "last_attempt_at") val lastAttemptAt: Instant? = null,
    @ColumnInfo(name = "next_attempt_at") val nextAttemptAt: Instant? = null,
    @ColumnInfo(name = "expected_object_path") val expectedObjectPath: String? = null,
    @ColumnInfo(name = "byte_size") val byteSize: Long,
    @ColumnInfo(name = "sha256_hex") val sha256Hex: String,
    @ColumnInfo(name = "last_http_status_code") val lastHttpStatusCode: Int? = null,
    @ColumnInfo(name = "last_request_id") val lastRequestId: String? = null,
)
