package ca.roadsense.ns.ui

import android.app.Application
import android.location.Location
import android.location.LocationManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.api.AppEnvironment
import ca.roadsense.ns.collection.CollectionService
import ca.roadsense.ns.data.room.FeedbackUploadState
import ca.roadsense.ns.data.room.PotholeActionUploadState
import ca.roadsense.ns.data.room.PrivacyZoneEntity
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.permissions.PermissionState
import ca.roadsense.ns.pothole.PotholeActionCoordinator
import ca.roadsense.ns.pothole.PotholeLocation
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.PrivacyZoneFactory
import ca.roadsense.ns.sensor.PrivacyZoneFilter
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
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
    val permissions: PermissionState = PermissionState(false, false, false, false, false),
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
        val running = app
            .getSharedPreferences(CollectionService.PREFS_NAME, android.content.Context.MODE_PRIVATE)
            .getBoolean(CollectionService.PREF_IS_RUNNING, false)
        val permissions = PermissionState.snapshot(app)
        val location = lastKnownLocation(app)

        _state.value = _state.value.copy(
            isRecording = running,
            permissions = permissions,
            lastLocation = location,
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

    fun onPermissionsChanged() = refresh()

    fun startRecording() {
        CollectionService.start(getApplication())
        refresh()
    }

    fun stopRecording() {
        CollectionService.stop(getApplication())
        enqueueDrain()
        refresh()
    }

    fun enqueueDrain() {
        val request = OneTimeWorkRequestBuilder<UploadDrainWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .addTag(UploadDrainWorker.TAG)
            .build()
        // enqueueUniqueWork + KEEP: if a drain is already queued/running,
        // don't stack another one on top of it. Combined with the Room
        // transaction in UploadDrainCoordinator, this closes both the
        // WorkManager-level and the DB-level route to two concurrent drains
        // selecting the same pending readings into separate batches.
        WorkManager.getInstance(getApplication()).enqueueUniqueWork(
            UploadDrainWorker.ONE_SHOT_WORK_NAME,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }

    /**
     * Submits a manual pothole report at the device's last known location.
     *
     * This used to return `UUID?` synchronously, but the id is only produced
     * inside the launched coroutine — the function returned (always null to
     * any caller) before that assignment ever ran. No production caller
     * actually used the return value (the UI observes `state.pendingActionId`
     * reactively instead), so the fix drops the misleading synchronous
     * return entirely rather than blocking the caller on the coroutine.
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
            // Same privacy-zone filter the passive collection pipeline uses
            // (`CollectionPipeline` → `PrivacyZoneFilter.shouldDrop`). A
            // manual report at home/work must be rejected exactly like a
            // passive reading would be dropped there — otherwise "mark
            // pothole here" is a hole in the privacy-zone guarantee.
            val zones = db.privacyZoneDao().list().map {
                PrivacyZone(latitude = it.latitude, longitude = it.longitude, radiusMeters = it.radiusM)
            }
            val sample = LocationSample(
                timestamp = location.timestampMillis / 1000.0,
                latitude = location.latitude,
                longitude = location.longitude,
                horizontalAccuracyMeters = location.accuracyMeters,
                speedKmh = 0.0,
                headingDegrees = 0.0,
            )
            if (PrivacyZoneFilter.shouldDrop(sample, zones)) {
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

    /** Adds a privacy zone at the device's last known location. Surfaces an
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
            enqueueDrain()
            refresh()
        }
    }

    fun deleteAllLocalData() {
        viewModelScope.launch {
            // Stop any active drive first to avoid the service writing back
            // into a freshly-cleared database.
            CollectionService.stop(getApplication())
            container.deleteAllLocalData()
            refresh()
        }
    }

    fun clearError() {
        _state.value = _state.value.copy(lastError = null)
    }

    private fun lastKnownLocation(app: Application): LocationSnapshot? {
        val manager = locationManager ?: return null
        if (PermissionState.snapshot(app).fineLocation.not()) return null
        // Order matters: GPS gives the freshest reading; NETWORK is the
        // last-resort fallback for indoors.
        val candidates = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        var best: Location? = null
        for (provider in candidates) {
            if (provider !in manager.allProviders) continue
            val loc = try {
                @Suppress("MissingPermission") manager.getLastKnownLocation(provider)
            } catch (_: SecurityException) {
                null
            } ?: continue
            if (best == null || loc.time > best.time) best = loc
        }
        return best?.let {
            LocationSnapshot(
                latitude = it.latitude,
                longitude = it.longitude,
                accuracyMeters = if (it.hasAccuracy()) it.accuracy.toDouble() else 0.0,
                timestampMillis = it.time,
            )
        }
    }

    companion object {
        const val STALE_FIX_MS: Long = 30_000
        const val DEFAULT_ZONE_RADIUS_METERS: Double = 250.0
    }
}
