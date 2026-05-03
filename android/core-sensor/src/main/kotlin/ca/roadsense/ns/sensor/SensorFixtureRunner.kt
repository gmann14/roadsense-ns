package ca.roadsense.ns.sensor

data class SensorFixtureReplayResult(
    val emittedReadings: List<PersistedReadingCandidate>,
    val privacyFilteredCount: Int,
    val rejectedCount: Int,
    val maxPotholeMagnitudeG: Double?,
)

object SensorFixtureRunner {
    fun replay(
        fixture: SensorFixture,
        privacyZones: List<PrivacyZone> = emptyList(),
    ): SensorFixtureReplayResult {
        var readingBuilder = ReadingBuilder()
        var potholeDetector = PotholeDetector()
        val emittedReadings = mutableListOf<PersistedReadingCandidate>()
        var recentPotholes = mutableListOf<PotholeCandidate>()
        var latestLocation: LocationSample? = null
        var latestGravity = MotionVector3(0.0, 0.0, 1.0)
        var thermalState = ThermalCollectionState.NOMINAL
        var isAutomotive = false
        var privacyFilteredCount = 0
        var rejectedCount = 0

        for (event in fixture.events) {
            when (event) {
                is SensorFixtureEvent.Activity -> {
                    if (!event.isAutomotive) {
                        readingBuilder = ReadingBuilder()
                        potholeDetector = PotholeDetector()
                        recentPotholes = mutableListOf()
                        latestLocation = null
                    }
                    isAutomotive = event.isAutomotive
                }

                is SensorFixtureEvent.Thermal -> {
                    thermalState = event.state
                }

                is SensorFixtureEvent.Gravity -> {
                    latestGravity = event.gravity
                }

                is SensorFixtureEvent.Accel -> {
                    if (!isAutomotive) continue
                    val motionSample = MotionSample(
                        timestamp = event.timestampEpochSeconds,
                        userAcceleration = event.userAcceleration,
                        gravity = latestGravity,
                    )
                    readingBuilder.addMotionSample(motionSample)

                    val location = latestLocation
                    if (location != null) {
                        val pothole = potholeDetector.ingest(
                            verticalAccelerationG = motionSample.verticalAcceleration,
                            currentLocation = location,
                        )
                        if (pothole != null) recentPotholes.add(pothole)
                    }
                }

                is SensorFixtureEvent.Gps -> {
                    if (!isAutomotive) continue
                    val sample = event.sample
                    latestLocation = sample

                    if (PrivacyZoneFilter.shouldDrop(sample, privacyZones)) {
                        privacyFilteredCount += 1
                        readingBuilder = ReadingBuilder()
                        potholeDetector = PotholeDetector()
                        recentPotholes = mutableListOf()
                        continue
                    }

                    val window = readingBuilder.addLocationSample(sample) ?: continue

                    val windowEnd = window.startedAt + window.durationSeconds
                    val potholesInWindow = recentPotholes.filter {
                        it.timestamp in window.startedAt..windowEnd
                    }

                    when (
                        val outcome = ReadingWindowProcessor.process(
                            window = window,
                            deviceState = DeviceCollectionState(
                                thermalState = thermalState,
                                isLowPowerModeEnabled = false,
                            ),
                            potholeCandidates = potholesInWindow,
                        )
                    ) {
                        is ReadingWindowProcessingOutcome.Accepted -> emittedReadings.add(outcome.candidate)
                        is ReadingWindowProcessingOutcome.Rejected -> rejectedCount += 1
                    }

                    recentPotholes.removeAll { it.timestamp <= windowEnd }
                }
            }
        }

        return SensorFixtureReplayResult(
            emittedReadings = emittedReadings.toList(),
            privacyFilteredCount = privacyFilteredCount,
            rejectedCount = rejectedCount,
            maxPotholeMagnitudeG = emittedReadings.mapNotNull { it.potholeMagnitudeG }.maxOrNull(),
        )
    }
}
