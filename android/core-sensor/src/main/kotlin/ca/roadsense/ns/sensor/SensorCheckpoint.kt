package ca.roadsense.ns.sensor

data class SensorCheckpoint(
    val savedAtEpochSeconds: Double,
    val wasCollecting: Boolean,
    val latestLocation: LocationSample?,
    val recentPotholes: List<PotholeCandidate>,
    val readingBuilder: ReadingBuilder.Snapshot,
    val potholeDetector: PotholeDetector.Snapshot,
) {
    fun isFresh(nowEpochSeconds: Double, maxAgeSeconds: Double): Boolean =
        nowEpochSeconds - savedAtEpochSeconds <= maxAgeSeconds
}
