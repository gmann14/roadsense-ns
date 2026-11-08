import Foundation

/// On-device retention rules (product spec: "30 days"; implementation doc 01
/// "Retention & Cleanup"). Applied by `ReadingStore.pruneExpiredLocalData`
/// on launch/foreground (throttled by `RetentionSweepThrottle`) and from the
/// `nightly-cleanup` background processing task.
public enum RetentionPolicy {
    public static let localRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

    public static func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-localRetentionInterval)
    }

    public static func pruneUploadedReadings(
        _ readings: [QueueReadingRecord],
        now: Date
    ) -> [QueueReadingRecord] {
        let cutoff = cutoff(now: now)

        return readings.filter { reading in
            guard let uploadedAt = reading.uploadedAt else {
                return true
            }

            return uploadedAt >= cutoff
        }
    }

    /// A local reading is removed when it can never be uploaded again and
    /// has outlived the retention window:
    /// - uploaded more than 30 days ago,
    /// - a privacy-zone stats row (counts only) recorded more than 30 days ago,
    /// - an endpoint-trimmed reading (never uploads) recorded more than 30 days ago.
    ///
    /// Readings still waiting to upload are always kept.
    public static func shouldPruneReading(
        recordedAt: Date,
        uploadedAt: Date?,
        endpointTrimmedAt: Date?,
        droppedByPrivacyZone: Bool,
        now: Date
    ) -> Bool {
        let cutoff = cutoff(now: now)

        if let uploadedAt {
            return uploadedAt < cutoff
        }

        if droppedByPrivacyZone || endpointTrimmedAt != nil {
            return recordedAt < cutoff
        }

        return false
    }

    /// Terminal upload batches older than the window are bookkeeping only.
    /// `failedPermanent` batches were rejected by the server (validation 4xx)
    /// and offered for manual retry; after 30 days their readings are pruned
    /// with them rather than kept forever.
    public static func shouldPruneBatch(
        status: QueueUploadStatus,
        createdAt: Date,
        lastAttemptAt: Date?,
        now: Date
    ) -> Bool {
        switch status {
        case .succeeded, .failedPermanent:
            return (lastAttemptAt ?? createdAt) < cutoff(now: now)
        case .pending, .inFlight:
            return false
        }
    }

    /// A sealed drive whose readings have all been pruned keeps only its
    /// start/end coordinates, which are the most sensitive points of a trip.
    /// Remove it once it is older than the window.
    public static func shouldPruneDriveSession(
        isSealed: Bool,
        startedAt: Date,
        endedAt: Date?,
        remainingReadingCount: Int,
        now: Date
    ) -> Bool {
        guard isSealed, remainingReadingCount == 0 else {
            return false
        }
        return (endedAt ?? startedAt) < cutoff(now: now)
    }
}

/// Limits the foreground retention sweep to once per `minimumInterval`; the
/// nightly background task runs it unconditionally.
public struct RetentionSweepThrottle: Equatable, Sendable {
    public static let defaultMinimumInterval: TimeInterval = 6 * 60 * 60

    public let minimumInterval: TimeInterval

    public init(minimumInterval: TimeInterval = defaultMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    public func shouldRun(lastRunAt: Date?, now: Date) -> Bool {
        guard let lastRunAt else {
            return true
        }
        // A clock moved backwards should not block cleanup indefinitely.
        if lastRunAt > now {
            return true
        }
        return now.timeIntervalSince(lastRunAt) >= minimumInterval
    }
}
