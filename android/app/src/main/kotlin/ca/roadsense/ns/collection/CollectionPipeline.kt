package ca.roadsense.ns.collection

import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.sensor.DeviceCollectionState
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.MotionSample
import ca.roadsense.ns.sensor.PotholeCandidate
import ca.roadsense.ns.sensor.PotholeDetector
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.PrivacyZoneFilter
import ca.roadsense.ns.sensor.ReadingBuilder
import ca.roadsense.ns.sensor.ReadingWindowProcessingOutcome
import ca.roadsense.ns.sensor.ReadingWindowProcessor
import ca.roadsense.ns.sensor.StationaryTracker
import ca.roadsense.ns.sensor.ThermalCollectionState
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.util.UUID

/**
 * Orchestrates the per-drive sensor pipeline: feeds motion + GPS samples to
 * `ReadingBuilder` + `PotholeDetector`, then writes accepted windows through
 * [DriveSessionGateway]. Mirrors the iOS `SensorFixtureRunner.replay` shape so
 * the shared CSV fixtures continue to be the parity contract.
 *
 * Drive sessions:
 * - a session opens on the first accurate (≤ [SESSION_START_MAX_ACCURACY_M])
 *   fix that shows movement, outside every privacy zone;
 * - every persisted reading carries that session id — with no open session
 *   nothing is persisted;
 * - after [StationaryTracker.autoEndAfterSeconds] without movement the
 *   session is sealed (endpoint-trimmed) and the next movement opens a new
 *   one, so a day parked at work produces two trimmed drives instead of one
 *   untrimmed one.
 *
 * All state changes from GPS, ticks and [endDrive] run under one [Mutex] so
 * interleaved suspend calls can't race session creation. Callers are expected
 * to invoke the pipeline from a single thread (the service's pipeline
 * dispatcher); [ingestMotion] is not suspend and relies on that.
 */
class CollectionPipeline(
    private val sessions: DriveSessionGateway,
    privacyZones: List<PrivacyZone>? = null,
    private val stationaryTracker: StationaryTracker = StationaryTracker(),
    /** Called after each session is sealed (Stop, auto-end, teardown); the
     *  service uses it to queue the drive-end upload. */
    private val onDriveSealed: () -> Unit = {},
) {
    private val mutex = Mutex()
    private var readingBuilder = ReadingBuilder()
    private var potholeDetector = PotholeDetector()
    private val recentPotholes = ArrayDeque<PotholeCandidate>()
    private var latestLocation: LocationSample? = null
    private var thermalState: ThermalCollectionState = ThermalCollectionState.NOMINAL
    private var driveSessionId: UUID? = null

    /** Null until the zones have been loaded; nothing is persisted before
     *  then, so a reading can never slip out before the filter is known. */
    @Volatile
    private var privacyZones: List<PrivacyZone>? = privacyZones

    /** Update privacy zones; the service calls this every time the stored
     *  zones change, so a zone added mid-drive applies to the next fix. */
    fun setPrivacyZones(zones: List<PrivacyZone>) {
        privacyZones = zones
    }

    fun setThermalState(state: ThermalCollectionState) {
        thermalState = state
    }

    /** Current open drive session, if any. */
    fun currentDriveSession(): UUID? = driveSessionId

    /** Most recent GPS fix ingested — used as the drive-end coordinate when
     *  sealing a session (mirrors iOS's fallback-end-sample resolution). */
    fun currentLocation(): LocationSample? = latestLocation

    fun ingestMotion(sample: MotionSample) {
        // Motion is buffered in memory only (capped by ReadingBuilder) and is
        // persisted only as part of a window under an open session. Before a
        // session opens it is kept so the first window covers the motion that
        // led up to the first moving fix (iOS parity, shared fixtures); every
        // stationary, inaccurate or in-zone fix clears it, so a parked phone
        // doesn't build up stale motion. Nothing is buffered until the
        // privacy zones are known.
        if (privacyZones == null) return
        readingBuilder.addMotionSample(sample)
        val location = latestLocation ?: return
        val candidate = potholeDetector.ingest(
            verticalAccelerationG = sample.verticalAcceleration,
            currentLocation = location,
        )
        if (candidate != null) recentPotholes.addLast(candidate)
    }

    /**
     * Feed a GPS sample. Returns the persisted row id when a window completed,
     * or null otherwise.
     */
    suspend fun ingestLocation(sample: LocationSample): UUID? = mutex.withLock {
        // Check before observing: the first fix after a long silent stop must
        // end the old drive, not count as movement that keeps it alive. The
        // seal uses the previous fix (where the car was parked).
        if (driveSessionId != null && stationaryTracker.shouldAutoEnd(sample.timestamp)) {
            endCurrentSession()
        }
        latestLocation = sample
        val moving = stationaryTracker.observe(sample)

        val zones = privacyZones
        if (zones == null || PrivacyZoneFilter.shouldDrop(sample, zones)) {
            // Zones unknown yet, or inside a zone: drop everything accumulated
            // in the trailing window — those samples can't be attributed
            // safely.
            resetWindow()
            return@withLock null
        }

        if (driveSessionId == null) {
            if (!moving || sample.horizontalAccuracyMeters > SESSION_START_MAX_ACCURACY_M) {
                resetWindow()
                return@withLock null
            }
            driveSessionId = sessions.openSession(sample)
        }
        val sessionId = driveSessionId ?: return@withLock null

        val window = readingBuilder.addLocationSample(sample) ?: return@withLock null

        val windowEnd = window.startedAt + window.durationSeconds
        val potholesInWindow = recentPotholes.filter {
            it.timestamp in window.startedAt..windowEnd
        }

        val outcome = ReadingWindowProcessor.process(
            window = window,
            deviceState = DeviceCollectionState(
                thermalState = thermalState,
                isLowPowerModeEnabled = false,
            ),
            potholeCandidates = potholesInWindow,
        )

        // Drain potholes consumed by this window so they don't double-count.
        recentPotholes.removeAll { it.timestamp <= windowEnd }

        when (outcome) {
            is ReadingWindowProcessingOutcome.Accepted -> {
                val id = UUID.randomUUID()
                val recorded = sessions.recordReading(
                    ReadingEntity(
                        id = id,
                        latitude = outcome.candidate.latitude,
                        longitude = outcome.candidate.longitude,
                        roughnessRMS = outcome.candidate.roughnessRMS,
                        speedKMH = outcome.candidate.speedKmh,
                        heading = outcome.candidate.headingDegrees,
                        gpsAccuracyM = outcome.candidate.gpsAccuracyMeters,
                        isPothole = outcome.candidate.isPothole,
                        potholeMagnitude = outcome.candidate.potholeMagnitudeG,
                        recordedAt = Instant.ofEpochMilli((outcome.candidate.recordedAtEpochSeconds * 1000).toLong()),
                        driveSessionId = sessionId,
                    ),
                )
                if (recorded) {
                    id
                } else {
                    // The session vanished (local data wiped). Start over on
                    // the next moving fix.
                    driveSessionId = null
                    resetWindow()
                    null
                }
            }

            is ReadingWindowProcessingOutcome.Rejected -> null
        }
    }

    /**
     * Periodic check from the service: seals the session once the car has
     * been still for the auto-end window. Needed because a parked phone may
     * not deliver any fixes at all. Returns true when a session was sealed.
     */
    suspend fun checkAutoEnd(nowEpochSeconds: Double): Boolean = mutex.withLock {
        if (driveSessionId == null || !stationaryTracker.shouldAutoEnd(nowEpochSeconds)) {
            return@withLock false
        }
        endCurrentSession()
        true
    }

    /** Ends the drive (Stop, service teardown, crash recovery). Idempotent. */
    suspend fun endDrive() {
        mutex.withLock { endCurrentSession() }
    }

    private suspend fun endCurrentSession() {
        val sessionId = driveSessionId ?: return
        driveSessionId = null
        resetWindow()
        stationaryTracker.reset()
        sessions.sealSession(sessionId, latestLocation)
        onDriveSealed()
    }

    private fun resetWindow() {
        readingBuilder = ReadingBuilder()
        potholeDetector = PotholeDetector()
        recentPotholes.clear()
    }

    companion object {
        /** A session's start coordinate drives endpoint trimming, so it must
         *  be a fix we trust (same bound `ReadingBuilder` uses for windows). */
        const val SESSION_START_MAX_ACCURACY_M: Double = 20.0
    }
}
