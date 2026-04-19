import Testing

@testable import RoadSenseNSBootstrap

@Suite("Motion math")
struct MotionMathTests {
    @Test("projects user acceleration onto gravity")
    func projectsUserAccelerationOntoGravity() {
        let value = MotionMath.verticalAcceleration(
            userAcceleration: MotionVector3(x: 0.1, y: 0.2, z: 0.9),
            gravity: MotionVector3(x: 0, y: 0, z: 1)
        )

        #expect(value == 0.9)
    }

    @Test("handles sideways device orientation")
    func handlesSidewaysDeviceOrientation() {
        let value = MotionMath.verticalAcceleration(
            userAcceleration: MotionVector3(x: 0.8, y: 0.1, z: 0.0),
            gravity: MotionVector3(x: 1, y: 0, z: 0)
        )

        #expect(value == 0.8)
    }

    @Test("returns zero for perpendicular movement")
    func returnsZeroForPerpendicularMovement() {
        let value = MotionMath.verticalAcceleration(
            userAcceleration: MotionVector3(x: 1, y: 0, z: 0),
            gravity: MotionVector3(x: 0, y: 0, z: 1)
        )

        #expect(value == 0)
    }
}
