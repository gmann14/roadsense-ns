package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

@Entity(tableName = "privacy_zones")
data class PrivacyZoneEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "label") val label: String,
    @ColumnInfo(name = "latitude") val latitude: Double,
    @ColumnInfo(name = "longitude") val longitude: Double,
    @ColumnInfo(name = "radius_m") val radiusM: Double,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
)
