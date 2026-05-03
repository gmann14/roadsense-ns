package ca.roadsense.ns.collection

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service that owns the sensor + GPS subscriptions for the
 * duration of an active drive. A12-3 ships the lifecycle skeleton + the
 * persistent notification; sensor wiring (SensorManager, FusedLocation)
 * lands once the manual + onboarding UI in A12-4 is the entry point.
 *
 * Persistent notification is `IMPORTANCE_LOW` so it doesn't ping; copy is
 * the user-facing answer to "why is RoadSense in my notification shade?"
 * Doc 14 (Play readiness) calls out that this notification screenshot is
 * what Play reviewers look for.
 */
class CollectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // A12-3 follow-on: subscribe to TYPE_LINEAR_ACCELERATION + TYPE_GRAVITY
        // + FusedLocationProviderClient here, route into a CollectionPipeline.
        // Keeping the service skeleton minimal until the wiring is tested on
        // a real device so we don't ship a broken-but-compiling service.

        return START_STICKY
    }

    override fun onDestroy() {
        // A12-3 follow-on: unsubscribe sensor + location listeners here.
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "roadsense.collection"
        const val NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, CollectionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CollectionService::class.java))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Drive collection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while RoadSense is recording road quality. Tap the app to stop."
            }
            manager.createNotificationChannel(channel)
        }

        private fun buildNotification(context: Context): Notification =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setOngoing(true)
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("Recording road quality")
                .setContentText("Tap RoadSense to stop")
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
    }
}
