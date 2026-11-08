import Foundation

@MainActor
protocol ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState { get }
    /// Emits the new thermal state whenever the system reports a change.
    func makeStateStream() -> AsyncStream<ProcessInfo.ThermalState>
}

extension ThermalMonitoring {
    /// Monitors that never change (test stubs, previews) emit nothing.
    func makeStateStream() -> AsyncStream<ProcessInfo.ThermalState> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
struct ThermalMonitor: ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    func makeStateStream() -> AsyncStream<ProcessInfo.ThermalState> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(ProcessInfo.processInfo.thermalState)
            }
            let token = ObserverToken(observer)
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.observer)
            }
        }
    }
}

/// Wraps the opaque observer object so it can be captured by the Sendable
/// termination handler.
private final class ObserverToken: @unchecked Sendable {
    let observer: NSObjectProtocol

    init(_ observer: NSObjectProtocol) {
        self.observer = observer
    }
}
