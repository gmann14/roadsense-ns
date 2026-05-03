package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

enum class UploadBatchState {
    PENDING,
    IN_FLIGHT,
    SUCCEEDED,
    FAILED_PERMANENT,
}

@Entity(
    tableName = "upload_batches",
    indices = [Index("state"), Index("next_attempt_at")],
)
data class UploadBatchEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "state") val state: UploadBatchState,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "last_attempt_at") val lastAttemptAt: Instant? = null,
    @ColumnInfo(name = "next_attempt_at") val nextAttemptAt: Instant? = null,
    @ColumnInfo(name = "attempt_count") val attemptCount: Int = 0,
    @ColumnInfo(name = "reading_count") val readingCount: Int = 0,
    @ColumnInfo(name = "last_http_status_code") val lastHttpStatusCode: Int? = null,
    @ColumnInfo(name = "last_request_id") val lastRequestId: String? = null,
)
