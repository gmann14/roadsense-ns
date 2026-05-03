package ca.roadsense.ns.collection

import ca.roadsense.ns.sensor.MotionSample
import ca.roadsense.ns.sensor.MotionVector3

/**
 * Glue between Android `SensorEvent`s and `core-sensor`'s `MotionSample`.
 *
 * Android delivers `TYPE_LINEAR_ACCELERATION` (gravity-removed acceleration)
 * and `TYPE_GRAVITY` as separate events, asynchronously. iOS delivers them
 * in a single `CMDeviceMotion` snapshot. The bridge keeps the latest gravity
 * vector and pairs it with each linear-acceleration event so that the rest
 * of the pipeline sees the same `MotionSample(userAcceleration, gravity)`
 * shape iOS emits.
 *
 * Pure logic — no Android API surface here so the contract is unit-testable
 * on the JVM.
 */
class SensorBridge(initialGravity: MotionVector3 = MotionVector3(0.0, 0.0, 1.0)) {
    private var latestGravity: MotionVector3 = initialGravity

    fun ingestGravity(vector: MotionVector3) {
        latestGravity = vector
    }

    /**
     * Build a `MotionSample` from a linear-acceleration event. Pairs it with
     * the most recent gravity vector. Timestamps are seconds-since-epoch
     * (Double) to match the iOS `TimeInterval` shape `core-sensor` expects.
     */
    fun ingestLinearAcceleration(
        userAcceleration: MotionVector3,
        timestampEpochSeconds: Double,
    ): MotionSample = MotionSample(
        timestamp = timestampEpochSeconds,
        userAcceleration = userAcceleration,
        gravity = latestGravity,
    )
}
