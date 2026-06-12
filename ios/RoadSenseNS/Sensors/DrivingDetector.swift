import CoreMotion
import Foundation

@MainActor
protocol DrivingDetecting {
    func makeEventStream() -> AsyncStream<Bool>
    func start()
    func stop()
}

@MainActor
final class DrivingDetector: DrivingDetecting {
    private let manager: CMMotionActivityManager
    private var continuation: AsyncStream<Bool>.Continuation?

    init(manager: CMMotionActivityManager = CMMotionActivityManager()) {
        self.manager = manager
    }

    /// Returns a fresh event stream, finishing any previously vended one.
    /// Streams are single-use: cancelling the consuming task terminates the
    /// stream permanently, so each monitoring session must consume its own.
    func makeEventStream() -> AsyncStream<Bool> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        self.continuation = continuation
        return stream
    }

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return
        }

        manager.startActivityUpdates(to: .main) { [continuation] activity in
            let isDriving = activity?.automotive == true && activity?.stationary != true
            continuation?.yield(isDriving)
        }
    }

    func stop() {
        manager.stopActivityUpdates()
    }
}
