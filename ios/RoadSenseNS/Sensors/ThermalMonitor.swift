import Foundation

@MainActor
protocol ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState { get }
}

@MainActor
struct ThermalMonitor: ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
