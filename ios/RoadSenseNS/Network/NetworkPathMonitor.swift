import Foundation
import Network

@MainActor
protocol NetworkPathProviding: AnyObject {
    var currentSnapshot: NetworkPathSnapshot { get }
}

/// Tracks connectivity via `NWPathMonitor` so upload drains can be gated on
/// network availability instead of burning retry attempts while offline, and
/// so queued batches can be requeued the moment connectivity returns.
@MainActor
final class NetworkPathMonitor: NetworkPathProviding {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ca.roadsense.network-path")
    private var isStarted = false

    /// Defaults to satisfied so uploads are never blocked before the first
    /// path update arrives.
    private(set) var currentSnapshot = NetworkPathSnapshot(status: .satisfied, isExpensive: false)

    var onPathBecameSatisfied: (@MainActor () -> Void)?

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(
                status: path.status == .satisfied ? .satisfied : .unsatisfied,
                isExpensive: path.isExpensive
            )
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else {
            return
        }

        isStarted = false
        monitor.cancel()
    }

    private func apply(_ snapshot: NetworkPathSnapshot) {
        let wasSatisfied = currentSnapshot.status == .satisfied
        currentSnapshot = snapshot

        if !wasSatisfied, snapshot.status == .satisfied {
            onPathBecameSatisfied?()
        }
    }
}

/// Glue between connectivity restoration and the upload queue: clears retry
/// backoff accumulated while offline, then kicks a drain so stranded batches
/// upload without waiting for the next foreground.
@MainActor
final class UploadConnectivityRestorer {
    private let queueStore: UploadQueueStore
    // Weak to avoid a retain cycle: the drain coordinator (owned by
    // AppContainer) retains the uploader, which retains the path monitor,
    // whose callback retains this restorer.
    private weak var drainCoordinator: (any UploadDrainCoordinating)?
    private let logger: RoadSenseLogger

    init(
        queueStore: UploadQueueStore,
        drainCoordinator: any UploadDrainCoordinating,
        logger: RoadSenseLogger
    ) {
        self.queueStore = queueStore
        self.drainCoordinator = drainCoordinator
        self.logger = logger
    }

    func handleNetworkRestored() async {
        do {
            try queueStore.requeueEligibleBatches()
        } catch {
            logger.error("failed to requeue batches after network restore: \(error.localizedDescription)")
        }

        guard let drainCoordinator else {
            return
        }

        _ = await drainCoordinator.requestDrain(reason: .networkRestored)
    }
}
