package ca.roadsense.ns.collection

import ca.roadsense.ns.data.room.ReadingDao
import ca.roadsense.ns.data.room.ReadingEntity
import ca.roadsense.ns.sensor.DeviceCollectionState
import ca.roadsense.ns.sensor.LocationSample
import ca.roadsense.ns.sensor.MotionSample
import ca.roadsense.ns.sensor.PotholeCandidate
import ca.roadsense.ns.sensor.PotholeDetector
import ca.roadsense.ns.sensor.PrivacyZone
import ca.roadsense.ns.sensor.PrivacyZoneFilter
import ca.roadsense.ns.sensor.ReadingBuilder
import ca.roadsense.ns.sensor.ReadingWindowProcessor
import ca.roadsense.ns.sensor.ReadingWindowProcessingOutcome
import ca.roadsense.ns.sensor.ThermalCollectionState
import java.time.Instant
import java.util.UUID

/**
 * Orchestrates the per-drive sensor pipeline: feeds motion + GPS samples to
 * `ReadingBuilder` + `PotholeDetector`, then writes accepted windows to
 * `ReadingDao`. Mirrors the iOS `SensorFixtureRunner.replay` shape so the
 * shared CSV fixtures continue to be the parity contract.
 *
 * State (latest gravity, recent potholes, builder, detector) lives here, not
 * in the Service, so a Robolectric test can drive the pipeline end-to-end
 * without standing up a Service.
 */
class CollectionPipeline(
    private val readingDao: ReadingDao,
    private var driveSessionId: UUID? = null,
    private var privacyZones: List<PrivacyZone> = emptyList(),
) {
    private var readingBuilder = ReadingBuilder()
    private var potholeDetector = PotholeDetector()
    private val recentPotholes = ArrayDeque<PotholeCandidate>()
    private var latestLocation: LocationSample? = null
    private var thermalState: ThermalCollectionState = ThermalCollectionState.NOMINAL

    /** Update privacy zones — onboarding/settings UI can swap these mid-drive. */
    fun setPrivacyZones(zones: List<PrivacyZone>) {
        privacyZones = zones
    }

    fun setThermalState(state: ThermalCollectionState) {
        thermalState = state
    }

    fun setDriveSession(id: UUID?) {
        driveSessionId = id
    }

    fun ingestMotion(sample: MotionSample) {
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
     * or null otherwise. Suspend so callers can write to Room without a
     * separate dispatcher dance.
     */
    suspend fun ingestLocation(sample: LocationSample): UUID? {
        latestLocation = sample

        if (PrivacyZoneFilter.shouldDrop(sample, privacyZones)) {
            // Drop everything we've accumulated in the trailing window — the
            // user crossed into a privacy zone, the prior samples can't be
            // attributed safely.
            readingBuilder = ReadingBuilder()
            potholeDetector = PotholeDetector()
            recentPotholes.clear()
            return null
        }

        val window = readingBuilder.addLocationSample(sample) ?: return null

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

        return when (outcome) {
            is ReadingWindowProcessingOutcome.Accepted -> {
                val id = UUID.randomUUID()
                readingDao.insert(
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
                        driveSessionId = driveSessionId,
                    )
                )
                id
            }

            is ReadingWindowProcessingOutcome.Rejected -> null
        }
    }
}
