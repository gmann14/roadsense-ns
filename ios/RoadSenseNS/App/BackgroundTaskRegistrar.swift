import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

enum BackgroundTaskRegistrar {
    static let nightlyCleanupTaskIdentifier = "ca.roadsense.ios.nightly-cleanup"
    static let uploadDrainTaskIdentifier = "ca.roadsense.ios.upload-drain"

    static func registerAll(logger: RoadSenseLogger) {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyCleanupTaskIdentifier, using: nil) { task in
            logger.info("background cleanup task fired: \(task.identifier)")
            task.setTaskCompleted(success: true)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: uploadDrainTaskIdentifier, using: nil) { task in
            logger.info("background upload drain task fired: \(task.identifier)")
            task.setTaskCompleted(success: true)
        }
        #else
        logger.info("background tasks unavailable in current build context")
        #endif
    }
}
