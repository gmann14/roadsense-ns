package ca.roadsense.ns.sensor

data class PersistedReadingCandidate(
    val latitude: Double,
    val longitude: Double,
    val roughnessRMS: Double,
    val speedKmh: Double,
    val headingDegrees: Double,
    val gpsAccuracyMeters: Double,
    val isPothole: Boolean,
    val potholeMagnitudeG: Double?,
    val recordedAtEpochSeconds: Double,
    val durationSeconds: Double,
)

sealed class ReadingWindowProcessingOutcome {
    data class Accepted(val candidate: PersistedReadingCandidate) : ReadingWindowProcessingOutcome()
    data class Rejected(val reason: QualityRejectionReason) : ReadingWindowProcessingOutcome()
}

object ReadingWindowProcessor {
    fun process(
        window: ReadingWindow,
        deviceState: DeviceCollectionState,
        potholeCandidates: List<PotholeCandidate>,
    ): ReadingWindowProcessingOutcome {
        return when (val decision = QualityFilter.evaluate(window, deviceState)) {
            QualityFilterDecision.Accepted -> ReadingWindowProcessingOutcome.Accepted(
                PersistedReadingCandidate(
                    latitude = window.latitude,
                    longitude = window.longitude,
                    roughnessRMS = window.roughnessRMS,
                    speedKmh = window.speedKmh,
                    headingDegrees = window.headingDegrees,
                    gpsAccuracyMeters = window.gpsAccuracyMeters,
                    isPothole = potholeCandidates.isNotEmpty(),
                    potholeMagnitudeG = potholeCandidates.maxOfOrNull { it.magnitudeG },
                    recordedAtEpochSeconds = window.startedAt + window.durationSeconds,
                    durationSeconds = window.durationSeconds,
                )
            )

            is QualityFilterDecision.Rejected -> ReadingWindowProcessingOutcome.Rejected(decision.reason)
        }
    }
}
