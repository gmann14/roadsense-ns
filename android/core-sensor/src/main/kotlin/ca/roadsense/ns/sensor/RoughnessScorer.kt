package ca.roadsense.ns.sensor

import kotlin.math.sqrt

class RoughnessScorer(
    val sampleRateHz: Double = 50.0,
    val cutoffHz: Double = 0.5,
    settleSampleCount: Int? = null,
) {
    val settleSampleCount: Int = settleSampleCount ?: sampleRateHz.toInt()

    fun score(samples: List<MotionSample>): Double =
        scoreVerticalAccelerations(samples.map { it.verticalAcceleration })

    fun scoreVerticalAccelerations(verticalAccelerations: List<Double>): Double {
        if (verticalAccelerations.isEmpty()) return 0.0

        val filter = HighPassBiquad.makeButterworth(sampleRateHz, cutoffHz)

        val first = verticalAccelerations.first()
        repeat(settleSampleCount) { filter.apply(first) }

        val filtered = verticalAccelerations.map { filter.apply(it) }
        val meanSquare = filtered.sumOf { it * it } / filtered.size.toDouble()
        return sqrt(meanSquare)
    }
}
