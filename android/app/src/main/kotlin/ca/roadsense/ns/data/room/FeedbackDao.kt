package ca.roadsense.ns.data.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.util.UUID

@Dao
interface FeedbackDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(entry: FeedbackEntity)

    @Update
    suspend fun update(entry: FeedbackEntity)

    @Query("SELECT * FROM feedback_queue WHERE id = :id LIMIT 1")
    suspend fun findById(id: UUID): FeedbackEntity?

    @Query(
        """
        SELECT * FROM feedback_queue
        WHERE upload_state = :pending
          AND (next_attempt_at IS NULL OR next_attempt_at <= :now)
        ORDER BY created_at ASC
        """,
    )
    suspend fun pending(pending: String, now: Instant): List<FeedbackEntity>

    @Query("SELECT COUNT(*) FROM feedback_queue WHERE upload_state = :pending")
    suspend fun pendingCount(pending: String): Int

    @Query("SELECT COUNT(*) FROM feedback_queue WHERE upload_state = :pending")
    fun observePendingCount(pending: String): Flow<Int>

    @Query("DELETE FROM feedback_queue WHERE id = :id")
    suspend fun delete(id: UUID): Int

    @Query("DELETE FROM feedback_queue")
    suspend fun deleteAll(): Int

    /** Submitted or permanently failed messages (message text + optional
     *  email) are not kept past the local retention window. */
    @Query(
        """
        DELETE FROM feedback_queue
        WHERE upload_state != :pending
          AND COALESCE(last_attempt_at, created_at) < :cutoff
        """,
    )
    suspend fun pruneFinishedBefore(pending: String, cutoff: Instant): Int

    /** "Upload now": make every pending message due immediately. */
    @Query("UPDATE feedback_queue SET next_attempt_at = NULL WHERE upload_state = :pending")
    suspend fun clearBackoff(pending: String): Int
}
