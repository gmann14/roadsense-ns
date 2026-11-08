package ca.roadsense.ns.ui

import android.app.Application
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ca.roadsense.ns.AppLog
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.api.AppEnvironment
import ca.roadsense.ns.collection.CollectionService
import ca.roadsense.ns.data.room.FeedbackUploadState
import ca.roadsense.ns.data.room.PrivacyZoneEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.permissions.PermissionState
import ca.roadsense.ns.pothole.PotholeActionCoordinator
import ca.roadsense.ns.pothole.PotholeLocation
import ca.roadsense.ns.sensor.PrivacyZoneFactory
import ca.roadsense.ns.sensor.PrivacyZoneFilter
import ca.roadsense.ns.toSensorZone
import ca.roadsense.ns.upload.UploadDrainWorker
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.security.SecureRandom
import java.time.Duration
import java.time.Instant
import java.util.UUID

/**
 * UI state container that the Compose surface observes. Wraps the lazy
 * `RoadSenseContainer` so we never have to worry about which thread or which
 * lifecycle initialised it.
 */
data class HomeState(
    val isRecording: Boolean = false,
    val pendingReadings: Int = 0,
    val pendingPotholeActions: Int = 0,
    val pendingFeedback: Int = 0,
    val totalDrives: Int = 0,
    val totalPotholesReported: Int = 0,
    val totalUploadedReadings: Long = 0,
    val lastLocation: LocationSnapshot? = null,
    val permissions: PermissionState = PermissionState(
        fineLocation = false,
        coarseLocation = false,
        notifications = false,
    ),
    val environment: AppEnvironment = AppEnvironment.STAGING,
    val appVersion: String = "0.0.0",
    val privacyZoneCount: Int = 0,
    val pendingActionId: UUID? = null,
    val pendingActionExpiresAt: Instant? = null,
    val lastError: String? = null,
)

data class LocationSnapshot(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double,
    val timestampMillis: Long,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val container: RoadSenseContainer = RoadSenseContainer.from(application)
    private val db: RoadSenseDatabase = container.database
    private val locationManager: LocationManager? =
        application.getSystemService(LocationManager::class.java)
    private val secureRandom = SecureRandom()
    private var observingLocation = false

    /** Live GPS while the app is on screen, so "Mark pothole here" and "Add
     *  privacy zone here" use where the phone is now, not a snapshot taken
     *  when the activity resumed. */
    private val liveLocationListener = LocationListener { location ->
        _state.value = _state.value.copy(lastLocation = location.toSnapshot())
    }

    /** Tracks the coroutine scheduled to auto-clear `pendingActionId` once
     *  the undo window lapses, so a second report (or Undo) can cancel a
     *  stale auto-clear instead of racing it. */
    private var pendingActionAutoClearJob: Job? = null

    private val _state = MutableStateFlow(
        HomeState(
            environment = container.config.environment,
            appVersion = container.clientAppVersion,
        )
    )
    val state: StateFlow<HomeState> = _state.asStateFlow()

    fun refresh() {
        val app = getApplication<Application>()
        val permissions = PermissionState.snapshot(app)

        _state.value = _state.value.copy(
            isRecording = CollectionService.isRecording(app),
            permissions = permissions,
            lastLocation = _state.value.lastLocation ?: lastKnownGpsLocation(permissions),
        )

        viewModelScope.launch {
            val pendingReadings = db.readingDao().pendingCount()
            val pendingActions = container.potholeActions.pendingUploadCount()
            val pendingFeedback = db.feedbackDao().pendingCount(FeedbackUploadState.PENDING.wireValue)
            val stats = db.userStatsDao().current()
            val zones = db.privacyZoneDao().list().size
            _state.value = _state.value.copy(
                pendingReadings = pendingReadings,
                pendingPotholeActions = pendingActions,
                pendingFeedback = pendingFeedback,
                totalDrives = stats?.totalDrives ?: 0,
                totalPotholesReported = stats?.totalPotholesReported ?: 0,
                totalUploadedReadings = stats?.totalUploadedReadings ?: 0L,
                privacyZoneCount = zones,
            )
        }
    }

    fun onPermissionsChanged() {
        refresh()
        if (observingLocation) {
            // A fresh grant should start the live feed without a restart.
            stopLocationUpdates()
            startLocationUpdates()
        }
    }

    /** Called from the activity's onStart. */
    fun startLocationUpdates() {
        val manager = locationManager ?: return
        if (!PermissionState.snapshot(getApplication()).fineLocation) return
        if (LocationManager.GPS_PROVIDER !in manager.allProviders) return
        try {
            manager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                LIVE_LOCATION_INTERVAL_MS,
                0f,
                liveLocationListener,
                Looper.getMainLooper(),
            )
            observingLocation = true
        } catch (e: SecurityException) {
            AppLog.warn("live location refused", e)
        } catch (e: IllegalArgumentException) {
            AppLog.warn("live location unavailable", e)
        }
    }

    /** Called from the activity's onStop: no GPS while the app is hidden
     *  (the collection service has its own subscription). */
    fun stopLocationUpdates() {
        observingLocation = false
        locationManager?.removeUpdates(liveLocationListener)
    }

    override fun onCleared() {
        stopLocationUpdates()
        super.onCleared()
    }

    fun startRecording() {
        if (!CollectionService.start(getApplication())) {
            _state.value = _state.value.copy(
                lastError = "Recording needs precise location. Grant it, then tap Start again.",
            )
        }
        refresh()
    }

    fun stopRecording() {
        // The service seals the drive in onDestroy and then queues the
        // drive-end upload itself, so the upload sees the trimmed readings.
        CollectionService.stop(getApplication())
        refresh()
    }

    /** "Upload pending drives now". */
    fun enqueueDrain() {
        UploadDrainWorker.enqueueOneShot(getApplication(), manual = true)
    }

    /**
     * Submits a manual pothole report at the device's current location.
     * Rejects a missing or stale fix rather than guessing.
     */
    fun reportPothole() {
        val location = _state.value.lastLocation ?: run {
            _state.value = _state.value.copy(
                lastError = "Pothole report needs a recent location fix. Move to a place with GPS and try again.",
            )
            return
        }
        if (location.timestampMillis < System.currentTimeMillis() - STALE_FIX_MS) {
            _state.value = _state.value.copy(
                lastError = "Last GPS fix is stale (>30s old). Wait for a fresh fix and try again.",
            )
            return
        }
        val now = Instant.now()
        viewModelScope.launch {
            // Same privacy-zone filter the passive collection pipeline uses.
            // A manual report at home/work must be rejected exactly like a
            // passive reading would be dropped there. Queued reports are
            // checked again at upload time (PotholeActionCoordinator) in
            // case a zone is added afterwards.
            val zones = container.privacyZones()
            if (PrivacyZoneFilter.isInside(location.latitude, location.longitude, zones)) {
                _state.value = _state.value.copy(
                    lastError = "You're inside a privacy zone — this location can't be reported.",
                )
                return@launch
            }

            val newId = container.potholeActions.reportPothole(
                PotholeLocation(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    accuracyM = location.accuracyMeters,
                ),
            )
            val expiresAt = now.plus(PotholeActionCoordinator.UNDO_WINDOW)
            _state.value = _state.value.copy(
                pendingActionId = newId,
                pendingActionExpiresAt = expiresAt,
                lastError = null,
            )
            refresh()
            scheduleAutoClear(newId, expiresAt)
        }
    }

    /** Clears `pendingActionId` once the undo window lapses so the report
     *  button (`enabled = ... && pendingActionId == null`) re-enables
     *  without the user having to tap Undo. Cancels any previously scheduled
     *  auto-clear so reports don't step on each other. */
    private fun scheduleAutoClear(actionId: UUID, expiresAt: Instant) {
        pendingActionAutoClearJob?.cancel()
        pendingActionAutoClearJob = viewModelScope.launch {
            val remaining = Duration.between(Instant.now(), expiresAt).toMillis().coerceAtLeast(0)
            delay(remaining)
            if (_state.value.pendingActionId == actionId) {
                _state.value = _state.value.copy(pendingActionId = null, pendingActionExpiresAt = null)
            }
        }
    }

    fun undoLastPothole() {
        val id = _state.value.pendingActionId ?: return
        pendingActionAutoClearJob?.cancel()
        viewModelScope.launch {
            container.potholeActions.undo(id)
            _state.value = _state.value.copy(pendingActionId = null, pendingActionExpiresAt = null)
            refresh()
        }
    }

    fun clearPendingActionMarker() {
        pendingActionAutoClearJob?.cancel()
        _state.value = _state.value.copy(pendingActionId = null, pendingActionExpiresAt = null)
    }

    /**
     * Creates a privacy zone centred (with a randomized offset, matching iOS
     * `PrivacyZoneFactory.makeZone` — never store the exact tapped
     * coordinate) around [latitude]/[longitude]. This is the only production
     * code path that inserts a `PrivacyZoneEntity`; wire a UI entry point to
     * this function rather than calling `privacyZoneDao().upsert` directly.
     * A running drive picks the zone up immediately (the service observes
     * the table).
     */
    fun addPrivacyZone(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = DEFAULT_ZONE_RADIUS_METERS,
        label: String = "Custom zone",
    ) {
        viewModelScope.launch {
            val zone = PrivacyZoneFactory.makeZone(
                tappedLatitude = latitude,
                tappedLongitude = longitude,
                requestedRadiusMeters = radiusMeters,
                randomAngleRadians = secureRandom.nextDouble() * 2 * Math.PI,
                randomDistanceMeters = 50.0 + secureRandom.nextDouble() * 50.0,
            )
            db.privacyZoneDao().upsert(
                PrivacyZoneEntity(
                    id = UUID.randomUUID(),
                    label = label,
                    latitude = zone.latitude,
                    longitude = zone.longitude,
                    radiusM = zone.radiusMeters,
                    createdAt = Instant.now(),
                ),
            )
            refresh()
        }
    }

    /** Adds a privacy zone at the device's current location. Surfaces an
     *  error via [HomeState.lastError] the same way [reportPothole] does when
     *  there's no usable fix. */
    fun addPrivacyZoneAtCurrentLocation(label: String = "Custom zone") {
        val location = _state.value.lastLocation ?: run {
            _state.value = _state.value.copy(
                lastError = "Adding a privacy zone needs a recent location fix. Move to a place with GPS and try again.",
            )
            return
        }
        addPrivacyZone(latitude = location.latitude, longitude = location.longitude, label = label)
    }

    fun submitFeedback(
        category: String,
        message: String,
        replyEmail: String?,
        contactConsent: Boolean,
    ) {
        viewModelScope.launch {
            container.feedbackQueue.enqueue(
                source = "android-settings",
                category = category,
                message = message,
                replyEmail = replyEmail?.takeIf { it.isNotBlank() },
                contactConsent = contactConsent,
                locale = java.util.Locale.getDefault().toLanguageTag(),
                route = null,
            )
            UploadDrainWorker.enqueueOneShot(getApplication(), manual = false)
            refresh()
        }
    }

    fun deleteAllLocalData() {
        // stopService never starts the service, so this can't crash when it
        // isn't running or location was revoked. Session writes are blocked
        // during the wipe, so a service still winding down can't write back.
        CollectionService.stop(getApplication())
        viewModelScope.launch {
            try {
                container.deleteAllLocalData()
                _state.value = _state.value.copy(pendingActionId = null, pendingActionExpiresAt = null)
            } catch (e: Exception) {
                AppLog.error("delete local data failed", e)
                _state.value = _state.value.copy(lastError = "Couldn't delete local data. Please try again.")
            }
            refresh()
        }
    }

    fun clearError() {
        _state.value = _state.value.copy(lastError = null)
    }

    /** Seeds the UI before the first live fix. GPS only; the staleness check
     *  in [reportPothole] still applies. */
    private fun lastKnownGpsLocation(permissions: PermissionState): LocationSnapshot? {
        val manager = locationManager ?: return null
        if (!permissions.fineLocation) return null
        if (LocationManager.GPS_PROVIDER !in manager.allProviders) return null
        return try {
            @Suppress("MissingPermission")
            manager.getLastKnownLocation(LocationManager.GPS_PROVIDER)?.toSnapshot()
        } catch (_: SecurityException) {
            null
        }
    }

    private fun Location.toSnapshot(): LocationSnapshot = LocationSnapshot(
        latitude = latitude,
        longitude = longitude,
        accuracyMeters = if (hasAccuracy()) accuracy.toDouble() else 999.0,
        timestampMillis = time,
    )

    companion object {
        const val STALE_FIX_MS: Long = 30_000
        const val LIVE_LOCATION_INTERVAL_MS: Long = 2_000
        const val DEFAULT_ZONE_RADIUS_METERS: Double = 250.0
    }
}
