package ca.roadsense.ns.sensor

data class MotionVector3(
    val x: Double,
    val y: Double,
    val z: Double,
)

data class MotionSample(
    val timestamp: Double,
    val userAcceleration: MotionVector3,
    val gravity: MotionVector3,
) {
    val verticalAcceleration: Double
        get() = MotionMath.verticalAcceleration(userAcceleration, gravity)
}

data class LocationSample(
    val timestamp: Double,
    val latitude: Double,
    val longitude: Double,
    val horizontalAccuracyMeters: Double,
    val speedKmh: Double,
    val headingDegrees: Double,
)

object MotionMath {
    fun verticalAcceleration(userAcceleration: MotionVector3, gravity: MotionVector3): Double =
        userAcceleration.x * gravity.x +
            userAcceleration.y * gravity.y +
            userAcceleration.z * gravity.z
}
