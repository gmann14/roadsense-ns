import CoreMotion
import Foundation

@MainActor
protocol MotionServicing {
    var samples: AsyncStream<MotionSample> { get }
    func start(hz: Double) throws
    func stop()
}

@MainActor
final class MotionService: MotionServicing {
    private let manager: CMMotionManager
    private let queue: OperationQueue
    private let continuation: AsyncStream<MotionSample>.Continuation
    let samples: AsyncStream<MotionSample>

    init(manager: CMMotionManager = CMMotionManager()) {
        self.manager = manager
        self.queue = OperationQueue()
        queue.name = "ca.roadsense.motion"
        queue.maxConcurrentOperationCount = 1

        var captured: AsyncStream<MotionSample>.Continuation?
        self.samples = AsyncStream<MotionSample> { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    func start(hz: Double = 50) throws {
        guard manager.isDeviceMotionAvailable else {
            throw NSError(domain: "RoadSenseNS.MotionService", code: 1)
        }

        manager.deviceMotionUpdateInterval = 1 / hz
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [continuation] motion, _ in
            guard let motion else {
                return
            }

            continuation.yield(
                MotionSample(
                    timestamp: motion.timestamp,
                    verticalAcceleration: MotionMath.verticalAcceleration(
                        userAcceleration: MotionVector3(
                            x: motion.userAcceleration.x,
                            y: motion.userAcceleration.y,
                            z: motion.userAcceleration.z
                        ),
                        gravity: MotionVector3(
                            x: motion.gravity.x,
                            y: motion.gravity.y,
                            z: motion.gravity.z
                        )
                    )
                )
            )
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
