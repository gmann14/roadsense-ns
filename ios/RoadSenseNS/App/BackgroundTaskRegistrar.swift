import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

private let backgroundTaskNowProvider: @Sendable () -> Date = { Date() }

/// One background-task run. Work does not start until `start()`, so the
/// caller can install `expirationHandler` on the BGTask first: an expiry that
/// arrives the instant the task launches is never missed.
@MainActor
final class BackgroundUploadDrainExecution {
    private let coordinator: any UploadDrainCoordinating
    private let nowProvider: @Sendable () -> Date
    private let scheduleNext: @MainActor @Sendable (Date) -> Void
    private let setTaskCompleted: @MainActor @Sendable (Bool) -> Void
    private(set) var task: Task<Void, Never>?

    init(
        coordinator: any UploadDrainCoordinating,
        nowProvider: @escaping @Sendable () -> Date,
        scheduleNext: @escaping @MainActor @Sendable (Date) -> Void,
        setTaskCompleted: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.nowProvider = nowProvider
        self.scheduleNext = scheduleNext
        self.setTaskCompleted = setTaskCompleted
    }

    /// Holds the execution strongly: the BGTask keeps this closure, which is
    /// what keeps the execution alive after the launch handler returns.
    nonisolated var expirationHandler: @Sendable () -> Void {
        { [self] in
            Task { @MainActor in
                self.expire()
            }
        }
    }

    func start() {
        guard task == nil else {
            return
        }

        task = Task { @MainActor [coordinator, nowProvider, scheduleNext, setTaskCompleted] in
            let success = await coordinator.requestDrain(reason: .backgroundTask)
            setTaskCompleted(success)
            scheduleNext(nowProvider().addingTimeInterval(15 * 60))
        }
    }

    func expire() {
        coordinator.cancelActiveDrain()
        task?.cancel()
    }
}

enum BackgroundUploadDrainRunner {
    @MainActor
    static func makeExecution(
        coordinator: any UploadDrainCoordinating,
        logger: RoadSenseLogger,
        nowProvider: @escaping @Sendable () -> Date = backgroundTaskNowProvider,
        scheduleNext: @escaping @MainActor @Sendable (Date) -> Void,
        setTaskCompleted: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> BackgroundUploadDrainExecution {
        BackgroundUploadDrainExecution(
            coordinator: coordinator,
            nowProvider: nowProvider,
            scheduleNext: scheduleNext,
            setTaskCompleted: setTaskCompleted
        )
    }
}

/// Nightly maintenance: retention pruning. Synchronous SwiftData work on the
/// main actor, so an expiry cannot interleave with it; the handler is still
/// installed first so a pre-start expiry completes the task cleanly.
enum NightlyCleanupRunner {
    static let interval: TimeInterval = 24 * 60 * 60

    @MainActor
    static func run(
        sweeper: LocalRetentionSweeper,
        isExpired: () -> Bool,
        now: Date = Date(),
        scheduleNext: (Date) -> Void,
        setTaskCompleted: (Bool) -> Void
    ) {
        defer { scheduleNext(now.addingTimeInterval(interval)) }
        guard !isExpired() else {
            setTaskCompleted(false)
            return
        }
        let summary = sweeper.runIfDue(force: true)
        setTaskCompleted(summary != nil)
    }
}

enum BackgroundTaskRegistrar {
    static let nightlyCleanupTaskIdentifier = "ca.roadsense.ios.nightly-cleanup"
    static let uploadDrainTaskIdentifier = "ca.roadsense.ios.upload-drain"

    /// Registers both launch handlers. They are registered on the main queue
    /// so the handlers can touch main-actor state (SwiftData stores, the
    /// drain coordinator) without hopping, and each sets its BGTask's
    /// expiration handler before any work begins.
    @MainActor
    static func registerAll(
        logger: RoadSenseLogger,
        uploadDrainCoordinator: any UploadDrainCoordinating,
        retentionSweeper: LocalRetentionSweeper
    ) {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyCleanupTaskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                logger.info("background cleanup task fired: \(task.identifier)")
                let expiry = ExpiryFlag()
                task.expirationHandler = { expiry.markExpired() }
                NightlyCleanupRunner.run(
                    sweeper: retentionSweeper,
                    isExpired: { expiry.isExpired },
                    scheduleNext: { earliestBegin in
                        scheduleNightlyCleanup(earliestBegin: earliestBegin, logger: logger)
                    },
                    setTaskCompleted: { success in
                        task.setTaskCompleted(success: success)
                    }
                )
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: uploadDrainTaskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
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
                execution.start()
            }
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

    /// Submits the nightly retention task. Needs the `processing` background
    /// mode, which is why Info.plist keeps it.
    @MainActor
    static func scheduleNightlyCleanup(
        earliestBegin: Date = Date().addingTimeInterval(NightlyCleanupRunner.interval),
        logger: RoadSenseLogger
    ) {
        #if canImport(BackgroundTasks)
        let request = BGProcessingTaskRequest(identifier: nightlyCleanupTaskIdentifier)
        request.earliestBeginDate = earliestBegin
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("scheduled nightly cleanup")
        } catch {
            logger.error("failed to schedule nightly cleanup: \(error.localizedDescription)")
        }
        #else
        logger.info("background cleanup scheduling unavailable in current build context")
        #endif
    }
}

/// Set from the BGTask expiration handler (main queue) and read by the
/// cleanup run on the main actor.
private final class ExpiryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func markExpired() {
        lock.lock()
        expired = true
        lock.unlock()
    }
}
