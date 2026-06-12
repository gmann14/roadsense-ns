package ca.roadsense.ns.data.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import java.time.Instant
import java.util.UUID

@Entity(tableName = "device_tokens")
data class DeviceTokenEntity(
    @PrimaryKey
    @ColumnInfo(name = "id") val id: UUID,
    @ColumnInfo(name = "token") val token: String,
    @ColumnInfo(name = "issued_at") val issuedAt: Instant,
    @ColumnInfo(name = "expires_at") val expiresAt: Instant,
)
