package ca.roadsense.ns.sensor

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

data class ReadingWindow(
    val latitude: Double,
    val longitude: Double,
    val roughnessRMS: Double,
    val speedKmh: Double,
    val headingDegrees: Double,
    val gpsAccuracyMeters: Double,
    val startedAt: Double,
    val durationSeconds: Double,
    val sampleCount: Int,
    val potholeSpikeCount: Int,
    val potholeMaxG: Double,
)

class ReadingBuilder(
    var targetDistanceMeters: Double = 40.0,
    var maxDurationSeconds: Double = 15.0,
    var maxHorizontalAccuracyMeters: Double = 20.0,
    var maxHeadingVarianceDegrees: Double = 60.0,
    var minimumSampleCount: Int = 30,
    var roughnessScorer: RoughnessScorer = RoughnessScorer(),
) {
    data class Snapshot(
        val targetDistanceMeters: Double,
        val maxDurationSeconds: Double,
        val maxHorizontalAccuracyMeters: Double,
        val maxHeadingVarianceDegrees: Double,
        val minimumSampleCount: Int,
        val locationSamples: List<LocationSample>,
        val motionSamples: List<MotionSample>,
    )

    private val locationSamples: MutableList<LocationSample> = mutableListOf()
    private val motionSamples: MutableList<MotionSample> = mutableListOf()

    constructor(snapshot: Snapshot) : this(
        targetDistanceMeters = snapshot.targetDistanceMeters,
        maxDurationSeconds = snapshot.maxDurationSeconds,
        maxHorizontalAccuracyMeters = snapshot.maxHorizontalAccuracyMeters,
        maxHeadingVarianceDegrees = snapshot.maxHeadingVarianceDegrees,
        minimumSampleCount = snapshot.minimumSampleCount,
    ) {
        locationSamples.addAll(snapshot.locationSamples)
        motionSamples.addAll(snapshot.motionSamples)
    }

    fun addMotionSample(sample: MotionSample) {
        motionSamples.add(sample)
    }

    fun addLocationSample(sample: LocationSample): ReadingWindow? {
        if (sample.horizontalAccuracyMeters > maxHorizontalAccuracyMeters) {
            reset()
            return null
        }

        if (locationSamples.isEmpty()) {
            locationSamples.add(sample)
            return null
        }

        locationSamples.add(sample)

        val duration = sample.timestamp - locationSamples[0].timestamp
        if (duration > maxDurationSeconds) {
            reset(startingWith = sample)
            return null
        }

        if (headingVarianceDegrees(locationSamples) > maxHeadingVarianceDegrees) {
            reset(startingWith = sample)
            return null
        }

        if (traveledDistanceMeters(locationSamples) < targetDistanceMeters) {
            return null
        }

        if (motionSamples.size < minimumSampleCount) {
            reset(startingWith = sample)
            return null
        }

        val midpoint = midpoint(locationSamples)
        val window = ReadingWindow(
            latitude = midpoint.first,
            longitude = midpoint.second,
            roughnessRMS = roughnessScorer.score(motionSamples),
            speedKmh = averageSpeed(locationSamples),
            headingDegrees = weightedHeading(locationSamples),
            gpsAccuracyMeters = locationSamples.maxOf { it.horizontalAccuracyMeters },
            startedAt = locationSamples[0].timestamp,
            durationSeconds = duration,
            sampleCount = motionSamples.size,
            potholeSpikeCount = 0,
            potholeMaxG = 0.0,
        )

        reset(startingWith = sample)
        return window
    }

    fun snapshot(): Snapshot = Snapshot(
        targetDistanceMeters = targetDistanceMeters,
        maxDurationSeconds = maxDurationSeconds,
        maxHorizontalAccuracyMeters = maxHorizontalAccuracyMeters,
        maxHeadingVarianceDegrees = maxHeadingVarianceDegrees,
        minimumSampleCount = minimumSampleCount,
        locationSamples = locationSamples.toList(),
        motionSamples = motionSamples.toList(),
    )

    private fun reset(startingWith: LocationSample? = null) {
        locationSamples.clear()
        if (startingWith != null) locationSamples.add(startingWith)
        motionSamples.clear()
    }

    private fun averageSpeed(samples: List<LocationSample>): Double =
        samples.sumOf { it.speedKmh } / samples.size

    private fun midpoint(samples: List<LocationSample>): Pair<Double, Double> {
        val totalDistance = traveledDistanceMeters(samples)
        val target = totalDistance / 2

        if (totalDistance <= 0 || samples.size <= 1) {
            val sample = samples[samples.size / 2]
            return sample.latitude to sample.longitude
        }

        var traversed = 0.0
        for (index in 1 until samples.size) {
            val previous = samples[index - 1]
            val current = samples[index]
            val segmentDistance = distanceMeters(previous, current)

            if (traversed + segmentDistance >= target && segmentDistance > 0) {
                val progress = (target - traversed) / segmentDistance
                return Pair(
                    previous.latitude + ((current.latitude - previous.latitude) * progress),
                    previous.longitude + ((current.longitude - previous.longitude) * progress),
                )
            }
            traversed += segmentDistance
        }

        val last = samples.last()
        return last.latitude to last.longitude
    }

    private fun traveledDistanceMeters(samples: List<LocationSample>): Double {
        if (samples.size <= 1) return 0.0
        var total = 0.0
        for (i in 1 until samples.size) {
            total += distanceMeters(samples[i - 1], samples[i])
        }
        return total
    }

    private fun distanceMeters(lhs: LocationSample, rhs: LocationSample): Double {
        val earthRadiusMeters = 6_371_000.0
        val lat1 = lhs.latitude * PI / 180
        val lat2 = rhs.latitude * PI / 180
        val deltaLat = (rhs.latitude - lhs.latitude) * PI / 180
        val deltaLon = (rhs.longitude - lhs.longitude) * PI / 180

        val a = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        val c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }

    private fun weightedHeading(samples: List<LocationSample>): Double {
        var x = 0.0
        var y = 0.0
        for (sample in samples) {
            val weight = if (sample.speedKmh > 0.1) sample.speedKmh else 0.1
            x += cos(sample.headingDegrees * PI / 180) * weight
            y += sin(sample.headingDegrees * PI / 180) * weight
        }
        val angle = atan2(y, x) * 180 / PI
        return if (angle >= 0) angle else angle + 360
    }

    private fun headingVarianceDegrees(samples: List<LocationSample>): Double {
        val mean = weightedHeading(samples)
        var maxDelta = 0.0
        for (sample in samples) {
            val delta = angularDistanceDegrees(sample.headingDegrees, mean)
            if (delta > maxDelta) maxDelta = delta
        }
        return maxDelta
    }

    private fun angularDistanceDegrees(lhs: Double, rhs: Double): Double {
        val raw = abs(lhs - rhs).mod(360.0)
        return min(raw, 360 - raw)
    }
}
