package ca.roadsense.ns.data.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import java.time.Instant
import java.util.UUID

@Dao
interface ReadingDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(reading: ReadingEntity)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertAll(readings: List<ReadingEntity>)

    @Update
    suspend fun update(reading: ReadingEntity)

    @Query("SELECT * FROM readings WHERE id = :id LIMIT 1")
    suspend fun findById(id: UUID): ReadingEntity?

    /**
     * Mirrors iOS upload-drain: pull a bounded slice of readings ready to
     * ship. Excludes privacy-zone-dropped, endpoint-trimmed, already-uploaded,
     * and drive-attached readings whose session hasn't been sealed yet.
     */
    @Query(
        """
        SELECT * FROM readings
        WHERE dropped_by_privacy_zone = 0
          AND uploaded_at IS NULL
          AND endpoint_trimmed_at IS NULL
          AND (drive_session_id IS NULL OR upload_ready_at IS NOT NULL)
          AND upload_batch_id IS NULL
        ORDER BY recorded_at ASC
        LIMIT :limit
        """,
    )
    suspend fun pendingForUpload(limit: Int): List<ReadingEntity>

    @Query("SELECT COUNT(*) FROM readings WHERE uploaded_at IS NULL AND dropped_by_privacy_zone = 0 AND endpoint_trimmed_at IS NULL")
    suspend fun pendingCount(): Int

    @Query("UPDATE readings SET upload_batch_id = :batchId WHERE id IN (:ids)")
    suspend fun assignBatch(ids: List<UUID>, batchId: UUID)

    @Query("UPDATE readings SET uploaded_at = :uploadedAt WHERE upload_batch_id = :batchId")
    suspend fun markBatchUploaded(batchId: UUID, uploadedAt: Instant)

    @Query("UPDATE readings SET upload_batch_id = NULL WHERE upload_batch_id = :batchId AND uploaded_at IS NULL")
    suspend fun releaseBatch(batchId: UUID)

    @Query(
        """
        DELETE FROM readings
        WHERE uploaded_at IS NOT NULL
          AND uploaded_at < :cutoff
        """,
    )
    suspend fun pruneUploadedBefore(cutoff: Instant): Int
}
