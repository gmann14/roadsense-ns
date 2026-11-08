package ca.roadsense.ns

import android.content.Context
import android.os.Build
import ca.roadsense.ns.collection.CollectionService
import ca.roadsense.ns.collection.DriveSessionLifecycle
import ca.roadsense.ns.collection.DriveSessionSealer
import ca.roadsense.ns.data.DeviceTokenStore
import ca.roadsense.ns.data.LocalDataWiper
import ca.roadsense.ns.data.LocalRetentionPruner
import ca.roadsense.ns.data.network.BackendClient
import ca.roadsense.ns.data.room.PrivacyZoneEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.feedback.FeedbackQueue
import ca.roadsense.ns.pothole.PotholeActionRepository
import ca.roadsense.ns.sensor.PrivacyZone
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File

/**
 * Process-wide singleton holding the long-lived data + network objects. Kept
 * intentionally tiny — Hilt is in the plan (per doc 12) but at this size the
 * manual container is cheaper to read and gives tests an explicit seam.
 */
class RoadSenseContainer private constructor(context: Context) {
    private val appContext: Context = context.applicationContext
    val database: RoadSenseDatabase = RoadSenseDatabase.build(appContext)
    val config = AppConfigProvider.current()
    val backendClient = BackendClient(config)
    val deviceTokenStore = DeviceTokenStore(database.deviceTokenDao())
    val potholeActions = PotholeActionRepository(database.potholeActionDao())
    val feedbackQueue = FeedbackQueue(database.feedbackDao())

    /** Background work that outlives a screen (orphan sweeps at launch). */
    val appScope: CoroutineScope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, error ->
            AppLog.error("background task failed", error)
        },
    )

    val driveSessions: DriveSessionLifecycle = DriveSessionLifecycle(
        driveSessionDao = database.driveSessionDao(),
        readingDao = database.readingDao(),
        sealer = DriveSessionSealer(
            database = database,
            driveSessionDao = database.driveSessionDao(),
            readingDao = database.readingDao(),
            privacyZones = { privacyZones() },
        ),
    )

    val retentionPruner = LocalRetentionPruner(database)

    val clientAppVersion: String =
        "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"
    val clientOSVersion: String = "Android ${Build.VERSION.RELEASE}"

    /** Pothole photos would live here once a capture UI exists. */
    val photoDirectory: File = File(appContext.filesDir, PHOTO_DIRECTORY_NAME)

    suspend fun privacyZones(): List<PrivacyZone> =
        database.privacyZoneDao().list().map(PrivacyZoneEntity::toSensorZone)

    /**
     * Hard-wipe of every Room table plus photo files. Mirrors the iOS
     * Settings → Delete local data control. Caller stops the foreground
     * service first; session writes are blocked for the duration either way.
     */
    suspend fun deleteAllLocalData() {
        LocalDataWiper(database, driveSessions, photoDirectory).wipe()
        CollectionService.clearRunningFlag(appContext)
    }

    companion object {
        const val PHOTO_DIRECTORY_NAME = "pothole-photos"

        @Volatile
        private var instance: RoadSenseContainer? = null

        fun from(context: Context): RoadSenseContainer =
            instance ?: synchronized(this) {
                instance ?: RoadSenseContainer(context).also { instance = it }
            }
    }
}

fun PrivacyZoneEntity.toSensorZone(): PrivacyZone =
    PrivacyZone(latitude = latitude, longitude = longitude, radiusMeters = radiusM)
