package ca.roadsense.ns.data.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import java.time.Instant
import java.util.UUID

@Dao
interface DriveSessionDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(session: DriveSessionEntity)

    @Update
    suspend fun update(session: DriveSessionEntity)

    @Query("SELECT * FROM drive_sessions WHERE id = :id LIMIT 1")
    suspend fun findById(id: UUID): DriveSessionEntity?

    @Query("SELECT * FROM drive_sessions WHERE is_sealed = 0 ORDER BY started_at DESC LIMIT 1")
    suspend fun openSession(): DriveSessionEntity?

    @Query("SELECT * FROM drive_sessions ORDER BY started_at DESC LIMIT :limit")
    suspend fun recent(limit: Int): List<DriveSessionEntity>

    /** Every session that was opened but never sealed, oldest first. */
    @Query("SELECT * FROM drive_sessions WHERE is_sealed = 0 ORDER BY started_at ASC")
    suspend fun unsealed(): List<DriveSessionEntity>

    /** Seals an open session. Returns 0 (and changes nothing) when the
     *  session is missing or already sealed, so a second seal is a no-op. */
    @Query(
        """
        UPDATE drive_sessions
        SET ended_at = :endedAt, end_latitude = :endLat, end_longitude = :endLng, is_sealed = 1
        WHERE id = :id AND is_sealed = 0
        """,
    )
    suspend fun seal(id: UUID, endedAt: Instant, endLat: Double, endLng: Double): Int

    /** Sealed sessions hold start/end coordinates (home, work); keep them
     *  only for the local retention window. */
    @Query("DELETE FROM drive_sessions WHERE is_sealed = 1 AND ended_at < :cutoff")
    suspend fun pruneSealedBefore(cutoff: Instant): Int

    @Query("DELETE FROM drive_sessions")
    suspend fun deleteAll(): Int
}
