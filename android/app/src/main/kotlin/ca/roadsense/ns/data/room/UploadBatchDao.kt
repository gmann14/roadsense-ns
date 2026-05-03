package ca.roadsense.ns.data.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import java.time.Instant
import java.util.UUID

@Dao
interface UploadBatchDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(batch: UploadBatchEntity)

    @Update
    suspend fun update(batch: UploadBatchEntity)

    @Query("SELECT * FROM upload_batches WHERE id = :id LIMIT 1")
    suspend fun findById(id: UUID): UploadBatchEntity?

    @Query(
        """
        SELECT * FROM upload_batches
        WHERE state = :state
          AND (next_attempt_at IS NULL OR next_attempt_at <= :now)
        ORDER BY created_at ASC
        LIMIT :limit
        """,
    )
    suspend fun nextDrainable(state: UploadBatchState, now: Instant, limit: Int): List<UploadBatchEntity>

    @Query("UPDATE upload_batches SET state = :state, last_attempt_at = :at, attempt_count = attempt_count + 1 WHERE id = :id")
    suspend fun markAttempt(id: UUID, state: UploadBatchState, at: Instant)

    @Query("DELETE FROM upload_batches WHERE state = :state AND last_attempt_at < :cutoff")
    suspend fun pruneTerminalBefore(state: UploadBatchState, cutoff: Instant): Int
}
