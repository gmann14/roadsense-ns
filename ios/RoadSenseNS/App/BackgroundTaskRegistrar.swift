import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

enum BackgroundTaskRegistrar {
    static let cleanupTaskIdentifier = "ca.roadsense.ios.cleanup"

    static func registerAll(logger: RoadSenseLogger) {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: cleanupTaskIdentifier, using: nil) { task in
            logger.info("background cleanup task fired: \(task.identifier)")
            task.setTaskCompleted(success: true)
        }
        #else
        logger.info("background tasks unavailable in current build context")
        #endif
    }
}
