import Foundation

/// Rate-limits the expensive SwiftData stats refresh that runs off the sensor
/// `stateDidChange` callback.
///
/// During an active drive the location manager emits a fix roughly every second,
/// and each one previously triggered ~10 SwiftData queries on the main actor
/// (status summaries, counts, the 500-row overlay fetch, user stats…). Sustained
/// over a long drive that churn is both a battery cost and a main-thread-hang risk.
///
/// This gate collapses those bursts to at most one heavy refresh per
/// `minimumInterval`. Callers should still force an immediate refresh on meaningful
/// transitions (collection start/stop) so user-visible counts stay correct, and
/// call `markRefreshed` whenever a full refresh happens through another path so the
/// window stays in sync.
public struct StatsRefreshThrottle {
    private let minimumInterval: TimeInterval
    private var lastRefreshAt: Date?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Returns `true` (and opens a new window) when enough time has elapsed since the
    /// last refresh; otherwise returns `false` and leaves the window untouched.
    public mutating func shouldRefresh(now: Date) -> Bool {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minimumInterval {
            return false
        }
        lastRefreshAt = now
        return true
    }

    /// Records that a full refresh just happened (e.g. from a non-throttled caller),
    /// resetting the throttle window.
    public mutating func markRefreshed(now: Date) {
        lastRefreshAt = now
    }
}
