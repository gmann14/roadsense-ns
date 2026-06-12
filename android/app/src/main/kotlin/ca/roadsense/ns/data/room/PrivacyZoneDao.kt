package ca.roadsense.ns.data.room

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow
import java.util.UUID

@Dao
interface PrivacyZoneDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(zone: PrivacyZoneEntity)

    @Delete
    suspend fun delete(zone: PrivacyZoneEntity)

    @Query("DELETE FROM privacy_zones WHERE id = :id")
    suspend fun deleteById(id: UUID): Int

    @Query("SELECT * FROM privacy_zones ORDER BY created_at ASC")
    suspend fun list(): List<PrivacyZoneEntity>

    @Query("SELECT * FROM privacy_zones ORDER BY created_at ASC")
    fun observe(): Flow<List<PrivacyZoneEntity>>

    @Query("DELETE FROM privacy_zones")
    suspend fun deleteAll(): Int
}
