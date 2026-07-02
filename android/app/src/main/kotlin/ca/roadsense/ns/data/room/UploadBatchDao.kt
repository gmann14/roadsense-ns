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

    /**
     * Batches stuck IN_FLIGHT — worker cancellation, process death, or a
     * non-IOException thrown mid-upload can all leave a batch marked
     * IN_FLIGHT with no code path left to move it forward, since
     * `nextDrainable` is only ever called with PENDING. Resetting stale
     * IN_FLIGHT batches (older than [cutoff]) back to PENDING makes them
     * drainable again on the next pass instead of stranding them forever.
     * Readings stay assigned to the batch (same as a normal retry) so no
     * double-upload risk is introduced.
     */
    @Query(
        """
        UPDATE upload_batches
        SET state = :pendingState
        WHERE state = :inFlightState
          AND (last_attempt_at IS NULL OR last_attempt_at < :cutoff)
        """,
    )
    suspend fun reclaimStaleInFlight(
        inFlightState: UploadBatchState,
        pendingState: UploadBatchState,
        cutoff: Instant,
    ): Int

    @Query("DELETE FROM upload_batches WHERE state = :state AND last_attempt_at < :cutoff")
    suspend fun pruneTerminalBefore(state: UploadBatchState, cutoff: Instant): Int

    @Query("DELETE FROM upload_batches")
    suspend fun deleteAll(): Int
}
