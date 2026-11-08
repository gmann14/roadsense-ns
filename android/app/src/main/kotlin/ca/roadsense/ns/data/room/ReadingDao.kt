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

    @Query("SELECT * FROM readings WHERE upload_batch_id = :batchId ORDER BY recorded_at ASC")
    suspend fun byBatch(batchId: UUID): List<ReadingEntity>

    @Query("SELECT * FROM readings WHERE drive_session_id = :driveSessionId ORDER BY recorded_at ASC")
    suspend fun byDriveSession(driveSessionId: UUID): List<ReadingEntity>

    /** Endpoint-trimming: hides a reading from upload forever (mirrors iOS —
     *  trimmed readings are never sent, matching `isReadyForUpload`). */
    @Query("UPDATE readings SET endpoint_trimmed_at = :trimmedAt WHERE id IN (:ids)")
    suspend fun markEndpointTrimmed(ids: List<UUID>, trimmedAt: Instant)

    /** Seals the drive-session gate — readings attached to a session are
     *  invisible to `pendingForUpload` until this runs (see
     *  `ReadingEntity.isReadyForUpload`). */
    @Query("UPDATE readings SET upload_ready_at = :readyAt WHERE id IN (:ids)")
    suspend fun markUploadReady(ids: List<UUID>, readyAt: Instant)

    /** Privacy zones applied after the fact (a zone added mid-drive or before
     *  upload): the reading never leaves the device. Also detaches it from a
     *  not-yet-uploaded batch so a retry never resends it. */
    @Query(
        """
        UPDATE readings
        SET dropped_by_privacy_zone = 1, upload_ready_at = NULL, upload_batch_id = NULL
        WHERE id IN (:ids) AND uploaded_at IS NULL
        """,
    )
    suspend fun markDroppedByPrivacyZone(ids: List<UUID>)

    /**
     * Mirrors iOS upload-drain: pull a bounded slice of readings ready to
     * ship. Only readings that belong to a drive session that has been sealed
     * (and therefore endpoint-trimmed) qualify. A reading with no drive
     * session is never uploaded — the pipeline cannot produce one, and if a
     * bug ever did, its endpoints were never trimmed.
     */
    @Query(
        """
        SELECT * FROM readings
        WHERE dropped_by_privacy_zone = 0
          AND uploaded_at IS NULL
          AND endpoint_trimmed_at IS NULL
          AND drive_session_id IS NOT NULL
          AND upload_ready_at IS NOT NULL
          AND upload_batch_id IS NULL
        ORDER BY recorded_at ASC
        LIMIT :limit
        """,
    )
    suspend fun pendingForUpload(limit: Int): List<ReadingEntity>

    /** Count of readings [pendingForUpload] would return (no limit). */
    @Query(
        """
        SELECT COUNT(*) FROM readings
        WHERE dropped_by_privacy_zone = 0
          AND uploaded_at IS NULL
          AND endpoint_trimmed_at IS NULL
          AND drive_session_id IS NOT NULL
          AND upload_ready_at IS NOT NULL
          AND upload_batch_id IS NULL
        """,
    )
    suspend fun readyForUploadCount(): Int

    @Query(
        """
        SELECT COUNT(*) FROM readings
        WHERE uploaded_at IS NULL
          AND dropped_by_privacy_zone = 0
          AND endpoint_trimmed_at IS NULL
          AND upload_batch_id IS NULL
        """,
    )
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

    /** Readings that can never upload (endpoint-trimmed, privacy-dropped, or
     *  stuck in a permanently failed batch) are kept only for the local
     *  retention window. They are exactly the rows nearest home/work, so
     *  keeping them forever would defeat the point of trimming. */
    @Query(
        """
        DELETE FROM readings
        WHERE uploaded_at IS NULL
          AND recorded_at < :cutoff
          AND (
            endpoint_trimmed_at IS NOT NULL
            OR dropped_by_privacy_zone = 1
            OR upload_batch_id IN (SELECT id FROM upload_batches WHERE state = 'FAILED_PERMANENT')
          )
        """,
    )
    suspend fun pruneNeverUploadableBefore(cutoff: Instant): Int

    @Query("DELETE FROM readings")
    suspend fun deleteAll(): Int
}
