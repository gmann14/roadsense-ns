import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

private let backgroundTaskNowProvider: @Sendable () -> Date = { Date() }

struct BackgroundUploadDrainExecution {
    let task: Task<Void, Never>
    let expirationHandler: @Sendable () -> Void
}

enum BackgroundUploadDrainRunner {
    @MainActor
    static func makeExecution(
        coordinator: any UploadDrainCoordinating,
        logger: RoadSenseLogger,
        nowProvider: @escaping @Sendable () -> Date = backgroundTaskNowProvider,
        scheduleNext: @escaping @Sendable (Date) -> Void,
        setTaskCompleted: @escaping @Sendable (Bool) -> Void
    ) -> BackgroundUploadDrainExecution {
        let work = Task { @MainActor in
            let success = await coordinator.requestDrain(reason: .backgroundTask)
            setTaskCompleted(success)
            scheduleNext(nowProvider().addingTimeInterval(15 * 60))
        }

        return BackgroundUploadDrainExecution(
            task: work,
            expirationHandler: {
                Task { @MainActor in
                    coordinator.cancelActiveDrain()
                }
                work.cancel()
            }
        )
    }
}

enum BackgroundTaskRegistrar {
    static let nightlyCleanupTaskIdentifier = "ca.roadsense.ios.nightly-cleanup"
    static let uploadDrainTaskIdentifier = "ca.roadsense.ios.upload-drain"

    @MainActor
    static func registerAll(
        logger: RoadSenseLogger,
        uploadDrainCoordinator: any UploadDrainCoordinating
    ) {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyCleanupTaskIdentifier, using: nil) { task in
            logger.info("background cleanup task fired: \(task.identifier)")
            task.setTaskCompleted(success: true)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: uploadDrainTaskIdentifier, using: nil) { task in
            logger.info("background upload drain task fired: \(task.identifier)")
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let execution = BackgroundUploadDrainRunner.makeExecution(
                coordinator: uploadDrainCoordinator,
                logger: logger,
                scheduleNext: { earliestBegin in
                    scheduleNextUploadDrain(
                        earliestBegin: earliestBegin,
                        logger: logger
                    )
                },
                setTaskCompleted: { success in
                    refreshTask.setTaskCompleted(success: success)
                }
            )
            refreshTask.expirationHandler = execution.expirationHandler
        }
        #else
        logger.info("background tasks unavailable in current build context")
        #endif
    }

    @MainActor
    static func scheduleNextUploadDrain(
        earliestBegin: Date,
        logger: RoadSenseLogger
    ) {
        #if canImport(BackgroundTasks)
        let request = BGAppRefreshTaskRequest(identifier: uploadDrainTaskIdentifier)
        request.earliestBeginDate = earliestBegin

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("scheduled upload drain for \(earliestBegin.formatted(date: .omitted, time: .shortened))")
        } catch {
            logger.error("failed to schedule upload drain: \(error.localizedDescription)")
        }
        #else
        logger.info("background upload scheduling unavailable in current build context")
        #endif
    }
}
