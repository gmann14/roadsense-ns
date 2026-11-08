package ca.roadsense.ns.collection

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import ca.roadsense.ns.AppLog
import ca.roadsense.ns.MainActivity
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.sensor.MotionVector3
import ca.roadsense.ns.sensor.ThermalCollectionState
import ca.roadsense.ns.toSensorZone
import ca.roadsense.ns.upload.UploadDrainWorker
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executors

/**
 * Foreground service that owns the sensor + GPS subscriptions for the
 * duration of an active drive.
 *
 * It is always started from the visible app (Start button), as a
 * `location`-typed foreground service. That is what lets it keep receiving
 * location with the screen off or the phone locked — no
 * `ACCESS_BACKGROUND_LOCATION` needed. It is deliberately `START_NOT_STICKY`:
 * on Android 14+ a system restart from the background could not start a
 * location foreground service anyway, and any session left open by a kill is
 * sealed by the orphan sweep on the next app or service start.
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
    private var autoEndJob: Job? = null
    private val sensorBridge = SensorBridge()
    private var isCollecting = false
    private var hasLinearAcceleration = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        container = RoadSenseContainer.from(this)
        sensorManager = getSystemService(SensorManager::class.java)
        locationManager = getSystemService(LocationManager::class.java)
        pipelineDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        // A failure inside the pipeline must not silently stop collection
        // with the drive left open: log it, report it, and seal what we have
        // so the readings recorded so far are trimmed and can upload.
        val crashHandler = CoroutineExceptionHandler { _, error ->
            AppLog.error("collection pipeline failed; sealing the current drive", error)
            sealAfterFailure()
        }
        pipelineScope = CoroutineScope(SupervisorJob() + pipelineDispatcher + crashHandler)
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // `stop()` uses stopService, so this branch only runs for a stray
            // ACTION_STOP intent. Never call startForeground() here: without
            // location permission that throws SecurityException.
            if (!isCollecting && hasLocationPermission() && startedAsForeground(intent)) {
                startForegroundSafely()
            }
            stopSelf()
            return START_NOT_STICKY
        }

        // A location-typed foreground service started without location
        // permission throws SecurityException on API 34+.
        if (!hasLocationPermission()) {
            AppLog.warn("collection start refused: location permission missing")
            clearRunningFlag(this)
            stopSelf()
            return START_NOT_STICKY
        }

        if (!startForegroundSafely()) {
            clearRunningFlag(this)
            stopSelf()
            return START_NOT_STICKY
        }

        if (!isCollecting) {
            isCollecting = true
            isRunningInProcess = true
            setRunningFlag(this, true)
            startCollection()
        }

        return START_NOT_STICKY
    }

    private fun startedAsForeground(intent: Intent): Boolean =
        intent.getBooleanExtra(EXTRA_STARTED_AS_FOREGROUND, false)

    private fun hasLocationPermission(): Boolean = hasFineLocationPermission(this)

    /** Returns false (instead of crashing) when the platform refuses the
     *  foreground start, e.g. permission revoked between check and call or a
     *  background start on Android 12+. */
    private fun startForegroundSafely(): Boolean {
        val notification = buildNotification(this)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            AppLog.warn("foreground start refused", e)
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) extends
            // IllegalStateException.
            val refused = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                e is ForegroundServiceStartNotAllowedException
            AppLog.warn(if (refused) "foreground start not allowed" else "foreground start failed", e)
            false
        }
    }

    override fun onDestroy() {
        sensorManager.unregisterListener(this)
        locationManager.removeUpdates(this)
        autoEndJob?.cancel()
        sealActiveDriveBlocking()
        isRunningInProcess = false
        isCollecting = false
        clearRunningFlag(this)
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
        pipelineScope.launch { pipeline?.ingestLocation(sample) }
    }

    /**
     * Seals the active drive before the service tears down. Runs on the
     * pipeline thread (so it can't interleave with an in-flight sample) and
     * blocks `onDestroy` for at most 5 s so a fast stop-then-relaunch can't
     * skip trimming. If it times out, the orphan sweep seals it next launch.
     */
    private fun sealActiveDriveBlocking() {
        val current = pipeline ?: return
        try {
            runBlocking(pipelineDispatcher) {
                withTimeoutOrNull(SEAL_TIMEOUT_MS) { current.endDrive() }
            }
        } catch (e: Exception) {
            AppLog.error("sealing the drive on stop failed", e)
        }
    }

    private fun sealAfterFailure() {
        val current = pipeline ?: return
        pipelineScope.launch {
            try {
                current.endDrive()
            } catch (e: Exception) {
                AppLog.error("sealing after a pipeline failure failed", e)
            }
        }
    }

    private fun startCollection() {
        val appContext = applicationContext
        val newPipeline = CollectionPipeline(
            sessions = container.driveSessions,
            // Upload as soon as a drive is sealed (Stop or auto-end) instead
            // of waiting for the 15-minute heartbeat.
            onDriveSealed = { UploadDrainWorker.enqueueOneShot(appContext, manual = false) },
        )
        newPipeline.setThermalState(currentThermalState())
        pipeline = newPipeline

        pipelineScope.launch {
            // A previous run killed mid-drive left its session unsealed; seal
            // and trim it before this drive starts (iOS parity:
            // finalizeOpenDriveSessions on launch).
            container.driveSessions.finalizeOrphans()
        }
        pipelineScope.launch {
            // Apply privacy zones live: any add/remove in Settings reaches
            // the running pipeline on the next fix.
            container.database.privacyZoneDao().observe().collect { zones ->
                newPipeline.setPrivacyZones(zones.map { it.toSensorZone() })
            }
        }
        autoEndJob = pipelineScope.launch {
            while (isActive) {
                delay(AUTO_END_CHECK_INTERVAL_MS)
                newPipeline.checkAutoEnd(System.currentTimeMillis() / 1000.0)
            }
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
        if (!hasLocationPermission()) {
            stopSelf()
            return
        }
        // GPS only. The NETWORK provider's coarse fixes reset reading
        // windows and could become a poor-accuracy session start point.
        if (!locationManager.allProviders.contains(LocationManager.GPS_PROVIDER)) {
            AppLog.warn("no GPS provider on this device; collection cannot run")
            stopSelf()
            return
        }
        try {
            locationManager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                LOCATION_INTERVAL_MS,
                LOCATION_MIN_DISTANCE_M,
                this,
                Looper.getMainLooper(),
            )
        } catch (e: SecurityException) {
            AppLog.warn("location updates refused", e)
            stopSelf()
        }
    }

    private fun currentThermalState(): ThermalCollectionState {
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

    companion object {
        const val CHANNEL_ID = "roadsense.collection"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "ca.roadsense.ns.collection.STOP"
        const val EXTRA_STARTED_AS_FOREGROUND = "ca.roadsense.ns.collection.STARTED_AS_FOREGROUND"
        const val PREFS_NAME = "collection"
        const val PREF_IS_RUNNING = "is_running"

        private const val SEAL_TIMEOUT_MS = 5_000L
        private const val AUTO_END_CHECK_INTERVAL_MS = 30_000L
        private const val LOCATION_INTERVAL_MS = 1_000L
        private const val LOCATION_MIN_DISTANCE_M = 5f

        /** True while a collecting service instance is alive in this process.
         *  The UI runs in the same process, so this is the source of truth
         *  for "is a drive recording"; the shared-preferences flag can be left
         *  stale by a process kill. */
        @Volatile
        var isRunningInProcess: Boolean = false
            private set

        fun hasFineLocationPermission(context: Context): Boolean =
            ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED

        /** Starts collection. No-op (returns false) without precise location
         *  permission, so the platform never sees a location FGS start it
         *  would reject. */
        fun start(context: Context): Boolean {
            if (!hasFineLocationPermission(context)) return false
            val intent = Intent(context, CollectionService::class.java)
                .putExtra(EXTRA_STARTED_AS_FOREGROUND, true)
            return try {
                context.startForegroundService(intent)
                true
            } catch (e: IllegalStateException) {
                AppLog.warn("could not start collection", e)
                false
            }
        }

        /**
         * Stops collection with `stopService`, which runs `onDestroy` (and
         * the drive seal inside it) when the service is alive and does
         * nothing when it isn't. It never starts a service, so it can never
         * trigger `startForeground()` — the old `startForegroundService(STOP)`
         * path crashed with SecurityException when the service was gone and
         * location permission had been revoked.
         *
         * Clears the running flag immediately, so a service that already died
         * can't leave the UI stuck on "Recording".
         */
        fun stop(context: Context) {
            context.stopService(Intent(context, CollectionService::class.java))
            clearRunningFlag(context)
        }

        /** Whether a drive is recording right now. Also repairs a stale
         *  "recording" flag left behind by a killed process. */
        fun isRecording(context: Context): Boolean {
            val flagged = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(PREF_IS_RUNNING, false)
            if (flagged && !isRunningInProcess) clearRunningFlag(context)
            return isRunningInProcess
        }

        fun clearRunningFlag(context: Context) = setRunningFlag(context, false)

        private fun setRunningFlag(context: Context, value: Boolean) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_IS_RUNNING, value)
                .apply()
        }

        private fun ensureChannel(context: Context) {
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
                    .setContentText("Tap to open RoadSense and stop. Ends on its own after 5 min parked.")
                    .setContentIntent(contentIntent)
                    .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                    .build()
            }
    }
}
