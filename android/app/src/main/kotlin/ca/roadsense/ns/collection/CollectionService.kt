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
import ca.roadsense.ns.sensor.MotionVector3
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.ThermalCollectionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
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
        pipelineScope = CoroutineScope(SupervisorJob() + pipelineDispatcher)
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

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

        if (!isCollecting) {
            isCollecting = true
            setRunning(true)
            startCollection()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        sensorManager.unregisterListener(this)
        locationManager.removeUpdates(this)
        setRunning(false)
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

    private fun startCollection() {
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
        if (ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.ACCESS_FINE_LOCATION,
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
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

        fun stop(context: Context) {
            context.stopService(Intent(context, CollectionService::class.java).setAction(ACTION_STOP))
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
