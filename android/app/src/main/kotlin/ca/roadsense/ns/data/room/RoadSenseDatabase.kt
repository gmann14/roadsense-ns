package ca.roadsense.ns.data.room

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters

/**
 * Single-process Room database. Schema version starts at 1; every future
 * migration lands alongside the feature that introduces it (per doc 12 §
 * Local persistence).
 *
 * `exportSchema = true` writes JSON schema files into
 * `app/schemas/RoadSenseDatabase/<version>.json` — those are committed so
 * migration tests can replay them and CI can detect accidental ABI breaks.
 */
@Database(
    entities = [
        ReadingEntity::class,
        UploadBatchEntity::class,
        PotholeActionEntity::class,
        PotholePhotoEntity::class,
        PrivacyZoneEntity::class,
        DeviceTokenEntity::class,
        DriveSessionEntity::class,
        UserStatsEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
@TypeConverters(Converters::class)
abstract class RoadSenseDatabase : RoomDatabase() {
    abstract fun readingDao(): ReadingDao
    abstract fun uploadBatchDao(): UploadBatchDao
    abstract fun potholeActionDao(): PotholeActionDao
    abstract fun potholePhotoDao(): PotholePhotoDao
    abstract fun privacyZoneDao(): PrivacyZoneDao
    abstract fun deviceTokenDao(): DeviceTokenDao
    abstract fun driveSessionDao(): DriveSessionDao
    abstract fun userStatsDao(): UserStatsDao

    companion object {
        const val DATABASE_NAME = "roadsense.db"

        fun build(context: Context): RoadSenseDatabase =
            Room.databaseBuilder(context, RoadSenseDatabase::class.java, DATABASE_NAME)
                // Migrations land alongside the schema change that needs them.
                // Until we ship a v2 schema there is nothing to migrate.
                .build()
    }
}
