package ca.roadsense.ns.sensor

enum class ThermalCollectionState { NOMINAL, FAIR, SERIOUS, CRITICAL }

data class DeviceCollectionState(
    val thermalState: ThermalCollectionState,
    val isLowPowerModeEnabled: Boolean,
)

enum class QualityRejectionReason {
    GPS_ACCURACY,
    SPEED,
    SAMPLE_COUNT,
    DURATION,
    THERMAL,
}

sealed class QualityFilterDecision {
    data object Accepted : QualityFilterDecision()
    data class Rejected(val reason: QualityRejectionReason) : QualityFilterDecision()
}

object QualityFilter {
    fun evaluate(
        reading: ReadingWindow,
        deviceState: DeviceCollectionState,
    ): QualityFilterDecision {
        if (reading.gpsAccuracyMeters > 20) return QualityFilterDecision.Rejected(QualityRejectionReason.GPS_ACCURACY)
        if (reading.speedKmh < 15 || reading.speedKmh > 160) return QualityFilterDecision.Rejected(QualityRejectionReason.SPEED)
        if (reading.sampleCount < 30) return QualityFilterDecision.Rejected(QualityRejectionReason.SAMPLE_COUNT)
        if (reading.durationSeconds > 15) return QualityFilterDecision.Rejected(QualityRejectionReason.DURATION)
        if (deviceState.thermalState == ThermalCollectionState.SERIOUS ||
            deviceState.thermalState == ThermalCollectionState.CRITICAL
        ) {
            return QualityFilterDecision.Rejected(QualityRejectionReason.THERMAL)
        }
        return QualityFilterDecision.Accepted
    }
}
