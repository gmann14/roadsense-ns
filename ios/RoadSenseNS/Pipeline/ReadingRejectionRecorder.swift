import Foundation
import SwiftData

/// Owns the in-memory accumulation of reading-rejection diagnostics for the
/// current sensor pipeline run, and flushes them to SwiftData on checkpoint /
/// session-seal boundaries. See `docs/implementation/15-rejection-diagnostics-plan.md`.
///
/// Key invariants:
/// - increments are O(1), no SwiftData on the hot path
/// - privacy-zone counts are not a second source of truth; that stays on
///   `ReadingRecord.droppedByPrivacyZone`. The recorder's mirror exists only
///   so a future export can render the same row.
/// - `collectionSample` events (e.g. pre-collection GPS samples) live in a
///   separate counter that resets on app launch. They are not "skipped reading
///   windows" and never leak into the reading-window totals.
@MainActor
final class ReadingRejectionRecorder {
    private let container: ModelContainer
    private let logger: RoadSenseLogger?

    // Cumulative deltas not yet persisted to SwiftData.
    private var pendingLifetimeDelta = ReadingDiagnosticTotals.empty
    private var pendingSessionDeltas: [UUID: ReadingDiagnosticTotals] = [:]
    private var preCollectionSampleCount = 0

    init(container: ModelContainer, logger: RoadSenseLogger? = nil) {
        self.container = container
        self.logger = logger
    }

    // MARK: Recording

    func recordReadingWindowReset(_ reason: ReadingDiagnosticReason, sessionID: UUID?) {
        guard reason.unit == .readingWindow else {
            return
        }
        increment(reason, sessionID: sessionID)
    }

    func recordQualityRejection(_ reason: QualityRejectionReason, sessionID: UUID?) {
        increment(reason.diagnosticReason, sessionID: sessionID)
    }

    func recordPersistFailure(sessionID: UUID?) {
        increment(.persistFailure, sessionID: sessionID)
    }

    func recordPartialAtSeal(sessionID: UUID?) {
        increment(.builderPartialAtSeal, sessionID: sessionID)
    }

    func recordPreCollectionLocationSample() {
        preCollectionSampleCount += 1
    }

    var preCollectionLocationSampleCount: Int {
        preCollectionSampleCount
    }

    var pendingLifetimeSnapshot: ReadingDiagnosticTotals {
        pendingLifetimeDelta
    }

    func pendingSessionSnapshot(for sessionID: UUID) -> ReadingDiagnosticTotals {
        pendingSessionDeltas[sessionID] ?? .empty
    }

    // MARK: Flush

    /// Writes accumulated deltas to SwiftData. Safe to call frequently — does
    /// nothing when there is nothing to write.
    @discardableResult
    func flush() -> Bool {
        guard !pendingLifetimeDelta.isEmpty || !pendingSessionDeltas.isEmpty else {
            return false
        }

        let context = ModelContext(container)
        var didWrite = false

        if !pendingLifetimeDelta.isEmpty,
           let stats = try? fetchUserStats(in: context) {
            var totals = ReadingDiagnosticTotals.decode(fromJSON: stats.rejectionTotalsJSON)
            totals.add(pendingLifetimeDelta)
            stats.rejectionTotalsJSON = totals.encodedJSON()
            didWrite = true
        }

        for (sessionID, delta) in pendingSessionDeltas where !delta.isEmpty {
            do {
                if let session = try fetchDriveSession(id: sessionID, in: context) {
                    var totals = ReadingDiagnosticTotals.decode(fromJSON: session.rejectionTotalsJSON)
                    totals.add(delta)
                    session.rejectionTotalsJSON = totals.encodedJSON()
                    didWrite = true
                }
            } catch {
                logger?.error("rejection recorder: failed to load session \(sessionID): \(error.localizedDescription)")
            }
        }

        if didWrite {
            do {
                try context.save()
                pendingLifetimeDelta = .empty
                pendingSessionDeltas.removeAll(keepingCapacity: true)
            } catch {
                logger?.error("rejection recorder: save failed: \(error.localizedDescription)")
                return false
            }
        }

        return didWrite
    }

    // MARK: Internal

    private func increment(_ reason: ReadingDiagnosticReason, sessionID: UUID?) {
        pendingLifetimeDelta.increment(reason)
        if let sessionID {
            pendingSessionDeltas[sessionID, default: .empty].increment(reason)
        }
    }

    private func fetchUserStats(in context: ModelContext) throws -> UserStats? {
        var descriptor = FetchDescriptor<UserStats>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let fresh = UserStats()
        context.insert(fresh)
        return fresh
    }

    private func fetchDriveSession(id: UUID, in context: ModelContext) throws -> DriveSessionRecord? {
        var descriptor = FetchDescriptor<DriveSessionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
