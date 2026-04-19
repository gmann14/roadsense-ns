import Foundation

public struct MotionVector3: Equatable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct MotionSample: Equatable, Sendable, Codable {
    public let timestamp: TimeInterval
    public let userAcceleration: MotionVector3
    public let gravity: MotionVector3

    public init(
        timestamp: TimeInterval,
        userAcceleration: MotionVector3,
        gravity: MotionVector3
    ) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
    }

    public var verticalAcceleration: Double {
        MotionMath.verticalAcceleration(
            userAcceleration: userAcceleration,
            gravity: gravity
        )
    }
}

public enum MotionMath {
    public static func verticalAcceleration(
        userAcceleration: MotionVector3,
        gravity: MotionVector3
    ) -> Double {
        userAcceleration.x * gravity.x +
        userAcceleration.y * gravity.y +
        userAcceleration.z * gravity.z
    }
}
