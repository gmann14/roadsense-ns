import Foundation
import SwiftData

@MainActor
final class UploadQueueStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func pendingReadingCount() throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate {
                $0.uploadedAt == nil && $0.droppedByPrivacyZone == false
            }
        )
        return try context.fetchCount(descriptor)
    }

    func prepareNextBatch(now: Date = Date()) throws -> QueuePreparationDecision {
        let context = ModelContext(container)
        let readings = try fetchPendingReadings(in: context)
        let existingBatch = try fetchExistingPendingBatch(in: context).map(QueueModelMapper.makeQueueBatch)

        let decision = UploadQueueCore.prepareNextBatch(
            pendingReadings: readings.map(QueueModelMapper.makeQueueReading),
            existingBatch: existingBatch,
            now: now,
            makeBatchID: UUID.init
        )

        switch decision {
        case .none:
            return .none
        case let .ready(batch, updatedReadings):
            try persist(batch: batch, readings: updatedReadings, in: context)
            return .ready(batch, updatedReadings)
        }
    }

    func payloadReadings(for batchID: UUID) throws -> [ReadingRecord] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate {
                $0.uploadBatchID == batchID && $0.droppedByPrivacyZone == false
            },
            sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func applySuccess(
        batchID: UUID,
        result: UploadServerResult,
        now: Date = Date()
    ) throws {
        let context = ModelContext(container)
        guard let batchModel = try fetchBatch(id: batchID, in: context) else {
            return
        }

        let readingModels = try fetchReadings(for: batchID, in: context)
        let outcome = UploadQueueCore.applySuccess(
            batch: QueueModelMapper.makeQueueBatch(from: batchModel),
            readings: readingModels.map(QueueModelMapper.makeQueueReading),
            result: result,
            now: now
        )

        QueueModelMapper.apply(outcome.batch, to: batchModel)
        for reading in readingModels {
            if let updated = outcome.readings.first(where: { $0.id == reading.id }) {
                QueueModelMapper.apply(updated, to: reading)
            }
        }
        try context.save()
    }

    func applyFailure(
        batchID: UUID,
        disposition: UploadDisposition,
        errorMessage: String?,
        now: Date = Date()
    ) throws {
        let context = ModelContext(container)
        guard let batchModel = try fetchBatch(id: batchID, in: context) else {
            return
        }

        let updated = UploadQueueCore.applyFailure(
            batch: QueueModelMapper.makeQueueBatch(from: batchModel),
            disposition: disposition,
            errorMessage: errorMessage,
            now: now
        )
        QueueModelMapper.apply(updated, to: batchModel)
        try context.save()
    }

    private func fetchPendingReadings(in context: ModelContext) throws -> [ReadingRecord] {
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate {
                $0.uploadedAt == nil && $0.droppedByPrivacyZone == false
            },
            sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    private func fetchExistingPendingBatch(in context: ModelContext) throws -> UploadBatch? {
        let descriptor = FetchDescriptor<UploadBatch>(
            predicate: #Predicate {
                $0.statusRawValue == UploadStatus.pending.rawValue || $0.statusRawValue == UploadStatus.inFlight.rawValue
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor).first
    }

    private func fetchBatch(id: UUID, in context: ModelContext) throws -> UploadBatch? {
        var descriptor = FetchDescriptor<UploadBatch>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchReadings(for batchID: UUID, in context: ModelContext) throws -> [ReadingRecord] {
        let descriptor = FetchDescriptor<ReadingRecord>(
            predicate: #Predicate { $0.uploadBatchID == batchID }
        )
        return try context.fetch(descriptor)
    }

    private func persist(
        batch: QueueUploadBatch,
        readings: [QueueReadingRecord],
        in context: ModelContext
    ) throws {
        let batchModel = try fetchBatch(id: batch.id, in: context) ?? {
            let model = UploadBatch(
                id: batch.id,
                createdAt: batch.createdAt,
                status: .pending,
                readingCount: batch.readingCount
            )
            context.insert(model)
            return model
        }()

        QueueModelMapper.apply(batch, to: batchModel)

        let readingIDs = Set(readings.map(\.id))
        if !readingIDs.isEmpty {
            let allReadings = try context.fetch(FetchDescriptor<ReadingRecord>())
            for model in allReadings where readingIDs.contains(model.id) {
                if let updated = readings.first(where: { $0.id == model.id }) {
                    QueueModelMapper.apply(updated, to: model)
                }
            }
        }

        try context.save()
    }
}
