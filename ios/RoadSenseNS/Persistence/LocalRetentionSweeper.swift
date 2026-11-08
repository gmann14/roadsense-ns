import Foundation

/// Applies the 30-day local retention policy. Runs on launch and foreground
/// (throttled so it costs one SwiftData pass every few hours at most) and,
/// unthrottled, from the nightly background-processing task.
@MainActor
final class LocalRetentionSweeper {
    static let lastRunDefaultsKey = "ca.roadsense.ios.retention.last-run-at"

    private let readingStore: ReadingStore
    private let defaults: UserDefaults
    private let throttle: RetentionSweepThrottle
    private let logger: RoadSenseLogger
    private let nowProvider: () -> Date

    init(
        readingStore: ReadingStore,
        defaults: UserDefaults = .standard,
        throttle: RetentionSweepThrottle = RetentionSweepThrottle(),
        logger: RoadSenseLogger = .app,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.readingStore = readingStore
        self.defaults = defaults
        self.throttle = throttle
        self.logger = logger
        self.nowProvider = nowProvider
    }

    var lastRunAt: Date? {
        defaults.object(forKey: Self.lastRunDefaultsKey) as? Date
    }

    /// Runs the sweep when the throttle window has elapsed (or always, with
    /// `force`). Returns nil when skipped or when the sweep failed.
    @discardableResult
    func runIfDue(force: Bool = false) -> LocalRetentionSweepSummary? {
        let now = nowProvider()
        guard force || throttle.shouldRun(lastRunAt: lastRunAt, now: now) else {
            return nil
        }

        do {
            try readingStore.scrubPrivacyFilteredCoordinates()
            let summary = try readingStore.pruneExpiredLocalData(now: now)
            defaults.set(now, forKey: Self.lastRunDefaultsKey)
            if summary.prunedReadingCount + summary.prunedBatchCount + summary.prunedDriveSessionCount > 0 {
                logger.info(
                    "retention sweep pruned readings=\(summary.prunedReadingCount) batches=\(summary.prunedBatchCount) drives=\(summary.prunedDriveSessionCount)"
                )
            }
            return summary
        } catch {
            logger.error("retention sweep failed: \(error.localizedDescription)")
            return nil
        }
    }
}
