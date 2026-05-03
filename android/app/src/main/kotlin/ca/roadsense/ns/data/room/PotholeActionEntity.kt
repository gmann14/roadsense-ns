package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

enum class PotholeActionType(val wireValue: String) {
    MANUAL_REPORT("manual_report"),
    CONFIRM_PRESENT("confirm_present"),
    CONFIRM_FIXED("confirm_fixed");

    companion object {
        fun fromWire(value: String): PotholeActionType =
            entries.firstOrNull { it.wireValue == value } ?: MANUAL_REPORT
    }
}

enum class PotholeActionUploadState(val wireValue: String) {
    PENDING_UNDO("pending_undo"),
    PENDING_UPLOAD("pending_upload"),
    FAILED_PERMANENT("failed_permanent");

    companion object {
        fun fromWire(value: String): PotholeActionUploadState =
            entries.firstOrNull { it.wireValue == value } ?: PENDING_UNDO
    }
}

@Entity(
    tableName = "pothole_actions",
    indices = [
        Index("upload_state"),
        Index("next_attempt_at"),
        Index("undo_expires_at"),
    ],
)
data class PotholeActionEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "pothole_report_id") val potholeReportId: UUID? = null,
    @ColumnInfo(name = "action_type") val actionType: String,
    @ColumnInfo(name = "latitude") val latitude: Double,
    @ColumnInfo(name = "longitude") val longitude: Double,
    @ColumnInfo(name = "accuracy_m") val accuracyM: Double,
    @ColumnInfo(name = "recorded_at") val recordedAt: Instant,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "undo_expires_at") val undoExpiresAt: Instant? = null,
    @ColumnInfo(name = "upload_state") val uploadState: String,
    @ColumnInfo(name = "upload_attempt_count") val uploadAttemptCount: Int = 0,
    @ColumnInfo(name = "last_attempt_at") val lastAttemptAt: Instant? = null,
    @ColumnInfo(name = "next_attempt_at") val nextAttemptAt: Instant? = null,
    @ColumnInfo(name = "last_http_status_code") val lastHttpStatusCode: Int? = null,
    @ColumnInfo(name = "last_request_id") val lastRequestId: String? = null,
    @ColumnInfo(name = "sensor_backed_magnitude_g") val sensorBackedMagnitudeG: Double? = null,
    @ColumnInfo(name = "sensor_backed_at") val sensorBackedAt: Instant? = null,
    @ColumnInfo(name = "uploaded_at") val uploadedAt: Instant? = null,
)
