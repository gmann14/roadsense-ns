import Foundation

private let coordinatorNowProvider: @Sendable () -> Date = { Date() }

@MainActor
protocol UploadDrainPerforming: AnyObject {
    func drainUntilBlocked(nowProvider: @escaping @Sendable () -> Date) async throws
}

enum UploadDrainReason: String {
    case foreground
    case backgroundTask
    case diagnosticsRetry
}

@MainActor
protocol UploadDrainCoordinating: AnyObject {
    func requestDrain(reason: UploadDrainReason) async -> Bool
    func cancelActiveDrain()
}

@MainActor
final class UploadDrainCoordinator: UploadDrainCoordinating {
    private let uploader: any UploadDrainPerforming
    private let logger: RoadSenseLogger
    private var activeDrainID: UUID?
    private var activeDrain: Task<Bool, Never>?

    init(
        uploader: any UploadDrainPerforming,
        logger: RoadSenseLogger
    ) {
        self.uploader = uploader
        self.logger = logger
    }

    func requestDrain(reason: UploadDrainReason) async -> Bool {
        if let activeDrain {
            return await activeDrain.value
        }

        let drainID = UUID()
        logger.info("upload drain requested: \(reason.rawValue)")
        let task = Task { @MainActor [uploader, logger] in
            do {
                try await uploader.drainUntilBlocked(nowProvider: coordinatorNowProvider)
                logger.info("upload drain completed: \(reason.rawValue)")
                return true
            } catch is CancellationError {
                logger.info("upload drain cancelled: \(reason.rawValue)")
                return false
            } catch {
                logger.error("upload drain failed: \(error.localizedDescription)")
                return false
            }
        }

        activeDrainID = drainID
        activeDrain = task
        let result = await task.value

        if activeDrainID == drainID {
            activeDrainID = nil
            activeDrain = nil
        }

        return result
    }

    func cancelActiveDrain() {
        activeDrain?.cancel()
    }
}
