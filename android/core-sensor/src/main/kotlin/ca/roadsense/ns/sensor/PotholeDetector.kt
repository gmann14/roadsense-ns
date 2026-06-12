package ca.roadsense.ns.sensor

data class PotholeCandidate(
    val latitude: Double,
    val longitude: Double,
    val magnitudeG: Double,
    val timestamp: Double,
)

class PotholeDetector(
    var spikeThresholdG: Double = 1.0,
    var dipThresholdG: Double = -0.3,
    var historyWindowSize: Int = 50,
    var dipLookbackSampleCount: Int = 5,
) {
    data class Snapshot(
        val spikeThresholdG: Double,
        val dipThresholdG: Double,
        val historyWindowSize: Int,
        val dipLookbackSampleCount: Int,
        val history: List<Double>,
    )

    private val history: ArrayDeque<Double> = ArrayDeque()

    constructor(snapshot: Snapshot) : this(
        spikeThresholdG = snapshot.spikeThresholdG,
        dipThresholdG = snapshot.dipThresholdG,
        historyWindowSize = snapshot.historyWindowSize,
        dipLookbackSampleCount = snapshot.dipLookbackSampleCount,
    ) {
        history.addAll(snapshot.history)
    }

    fun ingest(verticalAccelerationG: Double, currentLocation: LocationSample): PotholeCandidate? {
        history.addLast(verticalAccelerationG)
        while (history.size > historyWindowSize) history.removeFirst()

        if (verticalAccelerationG <= spikeThresholdG) return null

        // dropLast(1).takeLast(dipLookbackSampleCount) — same window iOS uses.
        val lookbackEnd = history.size - 1
        val lookbackStart = (lookbackEnd - dipLookbackSampleCount).coerceAtLeast(0)
        if (lookbackEnd <= lookbackStart) return null

        var minRecent = Double.POSITIVE_INFINITY
        for (i in lookbackStart until lookbackEnd) {
            if (history[i] < minRecent) minRecent = history[i]
        }
        if (minRecent >= dipThresholdG) return null

        return PotholeCandidate(
            latitude = currentLocation.latitude,
            longitude = currentLocation.longitude,
            magnitudeG = verticalAccelerationG,
            timestamp = currentLocation.timestamp,
        )
    }

    fun snapshot(): Snapshot = Snapshot(
        spikeThresholdG = spikeThresholdG,
        dipThresholdG = dipThresholdG,
        historyWindowSize = historyWindowSize,
        dipLookbackSampleCount = dipLookbackSampleCount,
        history = history.toList(),
    )
}
