package ca.roadsense.ns

import android.content.Context
import android.os.Build
import ca.roadsense.ns.data.DeviceTokenStore
import ca.roadsense.ns.data.network.BackendClient
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.feedback.FeedbackQueue
import ca.roadsense.ns.pothole.PotholeActionRepository

/**
 * Process-wide singleton holding the long-lived data + network objects. Kept
 * intentionally tiny — Hilt is in the plan (per doc 12) but at this size the
 * manual container is cheaper to read and gives tests an explicit seam.
 */
class RoadSenseContainer private constructor(context: Context) {
    val database: RoadSenseDatabase = RoadSenseDatabase.build(context.applicationContext)
    val config = AppConfigProvider.current()
    val backendClient = BackendClient(config)
    val deviceTokenStore = DeviceTokenStore(database.deviceTokenDao())
    val potholeActions = PotholeActionRepository(database.potholeActionDao())
    val feedbackQueue = FeedbackQueue(database.feedbackDao())

    val clientAppVersion: String =
        "${BuildConfig.APP_VERSION_NAME} (${BuildConfig.APP_VERSION_CODE})"
    val clientOSVersion: String = "Android ${Build.VERSION.RELEASE}"

    /**
     * Hard-wipe of every Room table. Mirrors the iOS Settings → Delete local
     * data control. Does not touch tile cache or shared-preferences flags.
     * Caller is responsible for stopping the foreground service first.
     */
    suspend fun deleteAllLocalData() {
        database.readingDao().deleteAll()
        database.uploadBatchDao().deleteAll()
        database.potholeActionDao().deleteAll()
        database.potholePhotoDao().deleteAll()
        database.privacyZoneDao().deleteAll()
        database.driveSessionDao().deleteAll()
        database.feedbackDao().deleteAll()
        database.userStatsDao().deleteAll()
        // Device token rotates monthly anyway; clearing forces a fresh token
        // so the wipe doesn't leak the prior token to the server's hash log.
        database.deviceTokenDao().deleteAll()
    }

    companion object {
        @Volatile
        private var instance: RoadSenseContainer? = null

        fun from(context: Context): RoadSenseContainer =
            instance ?: synchronized(this) {
                instance ?: RoadSenseContainer(context).also { instance = it }
            }
    }
}
