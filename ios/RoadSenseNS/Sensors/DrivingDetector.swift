import CoreMotion
import Foundation

@MainActor
protocol DrivingDetecting {
    var events: AsyncStream<Bool> { get }
    func start()
    func stop()
}

@MainActor
final class DrivingDetector: DrivingDetecting {
    private let manager: CMMotionActivityManager
    private let continuation: AsyncStream<Bool>.Continuation
    let events: AsyncStream<Bool>

    init(manager: CMMotionActivityManager = CMMotionActivityManager()) {
        self.manager = manager
        var captured: AsyncStream<Bool>.Continuation?
        self.events = AsyncStream<Bool> { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return
        }

        manager.startActivityUpdates(to: .main) { [continuation] activity in
            let isDriving = activity?.automotive == true && activity?.stationary != true
            continuation.yield(isDriving)
        }
    }

    func stop() {
        manager.stopActivityUpdates()
    }
}
