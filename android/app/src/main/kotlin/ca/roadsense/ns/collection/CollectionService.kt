package ca.roadsense.ns.collection

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import ca.roadsense.ns.MainActivity
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.data.room.DriveSessionEntity
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.MotionVector3
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.ThermalCollectionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Foreground service that owns the sensor + GPS subscriptions for the
 * duration of an active drive.
 *
 * Persistent notification is `IMPORTANCE_LOW` so it doesn't ping; copy is
 * the user-facing answer to "why is RoadSense in my notification shade?"
 */
class CollectionService : Service(), SensorEventListener, LocationListener {
    private lateinit var container: RoadSenseContainer
    private lateinit var sensorManager: SensorManager
    private lateinit var locationManager: LocationManager
    private lateinit var pipelineDispatcher: ExecutorCoroutineDispatcher
    private lateinit var pipelineScope: CoroutineScope
    private var pipeline: CollectionPipeline? = null
    private var sessionSealer: DriveSessionSealer? = null
    private val sensorBridge = SensorBridge()
    private var isCollecting = false
    private var hasLinearAcceleration = false
    private var creatingDriveSession = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        container = RoadSenseContainer.from(this)
        sensorManager = getSystemService(SensorManager::class.java)
        locationManager = getSystemService(LocationManager::class.java)
        pipelineDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        pipelineScope = CoroutineScope(SupervisorJob() + pipelineDispatcher)
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // If this instance was launched fresh via startForegroundService
            // just to deliver ACTION_STOP (e.g. the previous instance died),
            // the platform requires startForeground() to be called before we
            // can stop — otherwise API 26+ throws
            // ForegroundServiceDidNotStartInTimeException. A no-op
            // notification satisfies that contract; stopSelf() immediately
            // after tears it back down.
            if (!isCollecting) {
                startForegroundSafely()
            }
            stopSelf()
            return START_NOT_STICKY
        }

        // Location permission is required for FOREGROUND_SERVICE_TYPE_LOCATION
        // on API 34+; starting a location-typed foreground service without it
        // throws SecurityException and crash-loops the service (it gets
        // relaunched by START_STICKY, fails again, repeat). Check first and
        // bail out cleanly instead.
        if (!hasFineLocationPermission()) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundSafely()

        if (!isCollecting) {
            isCollecting = true
            setRunning(true)
            startCollection()
        }

        return START_STICKY
    }

    private fun hasFineLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_FINE_LOCATION,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun startForegroundSafely() {
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
    }

    override fun onDestroy() {
        sensorManager.unregisterListener(this)
        locationManager.removeUpdates(this)
        setRunning(false)
        sealActiveDriveSessionBlocking()
        pipelineScope.cancel()
        pipelineDispatcher.close()
        super.onDestroy()
    }

    override fun onSensorChanged(event: SensorEvent) {
        val timestamp = event.timestamp.toEpochSeconds()
        when (event.sensor.type) {
            Sensor.TYPE_GRAVITY -> sensorBridge.ingestGravity(event.asGVector())
            Sensor.TYPE_LINEAR_ACCELERATION -> {
                val sample = sensorBridge.ingestLinearAcceleration(event.asGVector(), timestamp)
                pipelineScope.launch { pipeline?.ingestMotion(sample) }
            }
            Sensor.TYPE_ACCELEROMETER -> {
                if (hasLinearAcceleration) return
                val sample = sensorBridge.ingestAccelerometer(event.asGVector(), timestamp)
                pipelineScope.launch { pipeline?.ingestMotion(sample) }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onLocationChanged(location: Location) {
        val sample = LocationBridge.fromCoordinates(
            timestampEpochSeconds = location.time.toDouble() / 1000.0,
            latitude = location.latitude,
            longitude = location.longitude,
            horizontalAccuracyMeters = if (location.hasAccuracy()) location.accuracy.toDouble() else 999.0,
            speedMetersPerSecond = if (location.hasSpeed()) location.speed.toDouble() else 0.0,
            bearingDegrees = if (location.hasBearing()) location.bearing.toDouble() else 0.0,
        )
        pipelineScope.launch {
            ensureDriveSession(sample)
            pipeline?.ingestLocation(sample)
        }
    }

    /**
     * Lazily creates the `DriveSessionEntity` for this drive on the first GPS
     * fix (mirrors iOS `ensureActiveDriveSession`) and tags the pipeline with
     * it so every reading persisted from here on carries `drive_session_id`.
     * Readings stay invisible to upload (`ReadingEntity.isReadyForUpload`)
     * until [DriveSessionSealer] seals the session at drive-end and applies
     * endpoint trimming — this is what actually keeps home/destination
     * coordinates off the wire.
     */
    private suspend fun ensureDriveSession(sample: LocationSample) {
        val current = pipeline ?: return
        if (current.currentDriveSession() != null || creatingDriveSession) return
        creatingDriveSession = true
        try {
            val sessionId = UUID.randomUUID()
            container.database.driveSessionDao().insert(
                DriveSessionEntity(
                    id = sessionId,
                    startedAt = Instant.ofEpochMilli((sample.timestamp * 1000).toLong()),
                    startLatitude = sample.latitude,
                    startLongitude = sample.longitude,
                ),
            )
            current.setDriveSession(sessionId)
        } finally {
            creatingDriveSession = false
        }
    }

    /**
     * Seals the active drive session and applies endpoint trimming before the
     * service tears down. Runs synchronously (bounded by a timeout) so the
     * seal completes before `onDestroy` returns — otherwise a fast
     * stop-then-relaunch could race the pipeline scope cancellation and skip
     * trimming entirely, which would be a privacy regression.
     */
    private fun sealActiveDriveSessionBlocking() {
        val current = pipeline ?: return
        val sessionId = current.currentDriveSession() ?: return
        val sealer = sessionSealer ?: return
        val endLocation = current.currentLocation()
        runBlocking {
            withTimeoutOrNull(5_000L) {
                sealer.sealAndTrim(
                    driveSessionId = sessionId,
                    endLatitude = endLocation?.latitude,
                    endLongitude = endLocation?.longitude,
                )
            }
        }
    }

    private fun startCollection() {
        sessionSealer = DriveSessionSealer(
            driveSessionDao = container.database.driveSessionDao(),
            readingDao = container.database.readingDao(),
        )
        pipelineScope.launch {
            val zones = container.database.privacyZoneDao().list().map {
                PrivacyZone(
                    latitude = it.latitude,
                    longitude = it.longitude,
                    radiusMeters = it.radiusM,
                )
            }
            pipeline = CollectionPipeline(
                readingDao = container.database.readingDao(),
                privacyZones = zones,
            )
            pipeline?.setThermalState(currentThermalState())
        }

        registerSensors()
        registerLocation()
    }

    private fun registerSensors() {
        sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY)?.also {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        val linear = sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
        if (linear != null) {
            hasLinearAcceleration = true
            sensorManager.registerListener(this, linear, SensorManager.SENSOR_DELAY_GAME)
        } else {
            hasLinearAcceleration = false
            sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.also {
                sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
            }
        }
    }

    private fun registerLocation() {
        // Belt-and-suspenders: onStartCommand already bails out before
        // startForeground() if permission is missing, but startCollection()
        // is also reachable indirectly, so keep this guard too.
        if (!hasFineLocationPermission()) {
            stopSelf()
            return
        }

        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        providers.forEach { provider ->
            if (locationManager.allProviders.contains(provider)) {
                locationManager.requestLocationUpdates(provider, 1_000L, 5f, this)
            }
        }
    }

    private fun currentThermalState(): ThermalCollectionState {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return ThermalCollectionState.NOMINAL
        val status = getSystemService(android.os.PowerManager::class.java)?.currentThermalStatus
            ?: return ThermalCollectionState.NOMINAL
        return when (status) {
            android.os.PowerManager.THERMAL_STATUS_LIGHT -> ThermalCollectionState.FAIR
            android.os.PowerManager.THERMAL_STATUS_MODERATE,
            android.os.PowerManager.THERMAL_STATUS_SEVERE -> ThermalCollectionState.SERIOUS
            android.os.PowerManager.THERMAL_STATUS_CRITICAL,
            android.os.PowerManager.THERMAL_STATUS_EMERGENCY,
            android.os.PowerManager.THERMAL_STATUS_SHUTDOWN -> ThermalCollectionState.CRITICAL
            else -> ThermalCollectionState.NOMINAL
        }
    }

    private fun SensorEvent.asGVector(): MotionVector3 {
        val divisor = SensorManager.GRAVITY_EARTH.toDouble()
        return MotionVector3(
            x = values[0].toDouble() / divisor,
            y = values[1].toDouble() / divisor,
            z = values[2].toDouble() / divisor,
        )
    }

    private fun Long.toEpochSeconds(): Double {
        val nowMillis = System.currentTimeMillis()
        val elapsedNanos = SystemClock.elapsedRealtimeNanos()
        return (nowMillis.toDouble() / 1000.0) + ((this - elapsedNanos).toDouble() / 1_000_000_000.0)
    }

    private fun setRunning(value: Boolean) {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_IS_RUNNING, value)
            .apply()
    }

    companion object {
        const val CHANNEL_ID = "roadsense.collection"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "ca.roadsense.ns.collection.STOP"
        const val PREFS_NAME = "collection"
        const val PREF_IS_RUNNING = "is_running"

        fun start(context: Context) {
            val intent = Intent(context, CollectionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * Stops collection. Uses `startService`/`startForegroundService`
         * (not `stopService`) so `ACTION_STOP` is actually delivered to
         * `onStartCommand` — `stopService()` tears the service down directly
         * and never invokes `onStartCommand`, which made the ACTION_STOP
         * branch there dead code and left `stopSelf()` (and the drive-session
         * seal it triggers via `onDestroy`) never called from this path.
         *
         * Also clears `PREF_IS_RUNNING` immediately, synchronously: if the
         * service already died (crash/force-stop), there's nothing alive to
         * deliver the intent to, and the flag would otherwise strand the UI
         * showing "Recording active" forever with no way to clear it short of
         * reinstalling. `onDestroy` clearing it again when the service *is*
         * alive is a harmless redundant write.
         */
        fun stop(context: Context) {
            val stopIntent = Intent(context, CollectionService::class.java).setAction(ACTION_STOP)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(stopIntent)
            } else {
                context.startService(stopIntent)
            }
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_IS_RUNNING, false)
                .apply()
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
            PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ).let { contentIntent ->
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setOngoing(true)
                    .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                    .setContentTitle("Recording road quality")
                    .setContentText("Tap RoadSense to stop")
                    .setContentIntent(contentIntent)
                    .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                    .build()
            }
    }
}
