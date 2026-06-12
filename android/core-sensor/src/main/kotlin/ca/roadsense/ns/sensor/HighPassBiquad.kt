package ca.roadsense.ns.sensor

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

class HighPassBiquad(
    val b0: Double,
    val b1: Double,
    val b2: Double,
    val a1: Double,
    val a2: Double,
) {
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    fun apply(x: Double): Double {
        val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    companion object {
        fun makeButterworth(sampleRateHz: Double, cutoffHz: Double): HighPassBiquad {
            val q = 1.0 / sqrt(2.0)
            val w0 = 2.0 * PI * cutoffHz / sampleRateHz
            val cosW0 = cos(w0)
            val sinW0 = sin(w0)
            val alpha = sinW0 / (2.0 * q)

            val rawB0 = (1.0 + cosW0) / 2.0
            val rawB1 = -(1.0 + cosW0)
            val rawB2 = (1.0 + cosW0) / 2.0
            val a0 = 1.0 + alpha
            val rawA1 = -2.0 * cosW0
            val rawA2 = 1.0 - alpha

            return HighPassBiquad(
                b0 = rawB0 / a0,
                b1 = rawB1 / a0,
                b2 = rawB2 / a0,
                a1 = rawA1 / a0,
                a2 = rawA2 / a0,
            )
        }
    }
}
