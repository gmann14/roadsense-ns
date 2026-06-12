package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import java.time.Instant

/**
 * Single-row "user stats" mirror of iOS `UserStats`. Pinned to id=1; this is
 * a deliberate single-row table — there's no multi-user concept. Updated by
 * the same reconciler iOS uses (see iOS BackgroundCollectionPolicy notes).
 */
@Entity(tableName = "user_stats")
data class UserStatsEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: Int = 1,
    @ColumnInfo(name = "total_drives") val totalDrives: Int = 0,
    @ColumnInfo(name = "total_distance_meters") val totalDistanceMeters: Double = 0.0,
    @ColumnInfo(name = "total_potholes_reported") val totalPotholesReported: Int = 0,
    @ColumnInfo(name = "total_uploaded_readings") val totalUploadedReadings: Long = 0,
    @ColumnInfo(name = "last_updated_at") val lastUpdatedAt: Instant? = null,
)
