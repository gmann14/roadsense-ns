package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

@Entity(
    tableName = "drive_sessions",
    indices = [Index("started_at"), Index("is_sealed")],
)
data class DriveSessionEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "started_at") val startedAt: Instant,
    @ColumnInfo(name = "ended_at") val endedAt: Instant? = null,
    @ColumnInfo(name = "start_latitude") val startLatitude: Double,
    @ColumnInfo(name = "start_longitude") val startLongitude: Double,
    @ColumnInfo(name = "end_latitude") val endLatitude: Double? = null,
    @ColumnInfo(name = "end_longitude") val endLongitude: Double? = null,
    @ColumnInfo(name = "is_sealed") val isSealed: Boolean = false,
)
