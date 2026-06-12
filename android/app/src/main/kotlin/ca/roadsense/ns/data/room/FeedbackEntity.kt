package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

enum class FeedbackUploadState(val wireValue: String) {
    PENDING("pending"),
    SUBMITTED("submitted"),
    FAILED_PERMANENT("failed_permanent");

    companion object {
        fun fromWire(value: String): FeedbackUploadState =
            entries.firstOrNull { it.wireValue == value } ?: PENDING
    }
}

/**
 * Mirror of iOS `FeedbackQueue` entries. Persists user-submitted feedback so
 * it survives process death and drains automatically when the app returns to
 * the foreground or the heartbeat upload-drain runs.
 */
@Entity(
    tableName = "feedback_queue",
    indices = [
        Index("upload_state"),
        Index("next_attempt_at"),
    ],
)
data class FeedbackEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "source") val source: String,
    @ColumnInfo(name = "category") val category: String,
    @ColumnInfo(name = "message") val message: String,
    @ColumnInfo(name = "reply_email") val replyEmail: String? = null,
    @ColumnInfo(name = "contact_consent") val contactConsent: Boolean,
    @ColumnInfo(name = "locale") val locale: String? = null,
    @ColumnInfo(name = "route") val route: String? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "upload_state") val uploadState: String = FeedbackUploadState.PENDING.wireValue,
    @ColumnInfo(name = "upload_attempt_count") val uploadAttemptCount: Int = 0,
    @ColumnInfo(name = "last_attempt_at") val lastAttemptAt: Instant? = null,
    @ColumnInfo(name = "next_attempt_at") val nextAttemptAt: Instant? = null,
    @ColumnInfo(name = "last_request_id") val lastRequestId: String? = null,
    @ColumnInfo(name = "last_field_errors") val lastFieldErrors: String? = null,
)
