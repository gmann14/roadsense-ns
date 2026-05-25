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
import ca.roadsense.ns.data.room.RoadSenseDatabase
import ca.roadsense.ns.permissions.PermissionState
import ca.roadsense.ns.pothole.PotholeLocation
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import ca.roadsense.ns.upload.UploadDrainWorker
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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
        WorkManager.getInstance(getApplication()).enqueue(request)
    }

    fun reportPothole(): UUID? {
        val location = _state.value.lastLocation ?: run {
            _state.value = _state.value.copy(
                lastError = "Pothole report needs a recent location fix. Move to a place with GPS and try again.",
            )
            return null
        }
        if (location.timestampMillis < System.currentTimeMillis() - STALE_FIX_MS) {
            _state.value = _state.value.copy(
                lastError = "Last GPS fix is stale (>30s old). Wait for a fresh fix and try again.",
            )
            return null
        }
        val now = Instant.now()
        var newId: UUID? = null
        viewModelScope.launch {
            newId = container.potholeActions.reportPothole(
                PotholeLocation(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    accuracyM = location.accuracyMeters,
                ),
            )
            _state.value = _state.value.copy(
                pendingActionId = newId,
                pendingActionExpiresAt = now.plus(java.time.Duration.ofSeconds(8)),
                lastError = null,
            )
            refresh()
        }
        return newId
    }

    fun undoLastPothole() {
        val id = _state.value.pendingActionId ?: return
        viewModelScope.launch {
            container.potholeActions.undo(id)
            _state.value = _state.value.copy(pendingActionId = null, pendingActionExpiresAt = null)
            refresh()
        }
    }

    fun clearPendingActionMarker() {
        _state.value = _state.value.copy(pendingActionId = null, pendingActionExpiresAt = null)
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
    }
}
