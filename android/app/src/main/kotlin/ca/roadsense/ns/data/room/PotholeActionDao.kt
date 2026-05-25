package ca.roadsense.ns.data.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import java.time.Instant
import java.util.UUID

@Dao
interface PotholeActionDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(action: PotholeActionEntity)

    @Update
    suspend fun update(action: PotholeActionEntity)

    @Query("DELETE FROM pothole_actions WHERE id = :id")
    suspend fun delete(id: UUID): Int

    @Query("SELECT * FROM pothole_actions WHERE id = :id LIMIT 1")
    suspend fun findById(id: UUID): PotholeActionEntity?

    /**
     * Pending uploads — actions whose undo window has elapsed and whose
     * backoff window has elapsed. Mirrors iOS' `PotholeActionUploader` query.
     */
    @Query(
        """
        SELECT * FROM pothole_actions
        WHERE upload_state = :pendingUpload
          AND uploaded_at IS NULL
          AND (undo_expires_at IS NULL OR undo_expires_at <= :now)
          AND (next_attempt_at IS NULL OR next_attempt_at <= :now)
        ORDER BY created_at ASC
        """,
    )
    suspend fun pendingForUpload(pendingUpload: String, now: Instant): List<PotholeActionEntity>

    @Query(
        """
        SELECT * FROM pothole_actions
        WHERE upload_state = :pendingUndo
          AND undo_expires_at IS NOT NULL
          AND undo_expires_at <= :now
        ORDER BY created_at ASC
        """,
    )
    suspend fun expiredUndos(pendingUndo: String, now: Instant): List<PotholeActionEntity>

    @Query("SELECT COUNT(*) FROM pothole_actions WHERE upload_state = :pendingUpload")
    suspend fun pendingUploadCount(pendingUpload: String): Int

    @Query("DELETE FROM pothole_actions")
    suspend fun deleteAll(): Int
}

@Dao
interface PotholePhotoDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(photo: PotholePhotoEntity)

    @Update
    suspend fun update(photo: PotholePhotoEntity)

    @Query("SELECT * FROM pothole_photos WHERE id = :id LIMIT 1")
    suspend fun findById(id: UUID): PotholePhotoEntity?

    @Query(
        """
        SELECT * FROM pothole_photos
        WHERE upload_state = :pendingMetadata
          AND (next_attempt_at IS NULL OR next_attempt_at <= :now)
        ORDER BY captured_at ASC
        """,
    )
    suspend fun pendingMetadata(pendingMetadata: String, now: Instant): List<PotholePhotoEntity>

    @Query("DELETE FROM pothole_photos WHERE id = :id")
    suspend fun delete(id: UUID): Int

    @Query("DELETE FROM pothole_photos")
    suspend fun deleteAll(): Int
}

@Dao
interface DeviceTokenDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(token: DeviceTokenEntity)

    @Query("SELECT * FROM device_tokens ORDER BY issued_at DESC LIMIT 1")
    suspend fun current(): DeviceTokenEntity?

    @Query("DELETE FROM device_tokens WHERE expires_at < :cutoff")
    suspend fun pruneExpiredBefore(cutoff: Instant): Int

    @Query("DELETE FROM device_tokens")
    suspend fun deleteAll(): Int
}

@Dao
interface UserStatsDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(stats: UserStatsEntity)

    @Query("SELECT * FROM user_stats WHERE id = 1 LIMIT 1")
    suspend fun current(): UserStatsEntity?

    @Query("DELETE FROM user_stats")
    suspend fun deleteAll(): Int
}
