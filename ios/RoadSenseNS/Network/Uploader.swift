import Foundation
import SwiftData

@MainActor
final class Uploader {
    private let container: ModelContainer
    private let queueStore: UploadQueueStore
    private let client: APIClient
    private let logger: RoadSenseLogger

    init(
        container: ModelContainer,
        queueStore: UploadQueueStore,
        client: APIClient,
        logger: RoadSenseLogger
    ) {
        self.container = container
        self.queueStore = queueStore
        self.client = client
        self.logger = logger
    }

    func drainOnce(now: Date = Date()) async {
        do {
            let decision = try queueStore.prepareNextBatch(now: now)
            guard case let .ready(batch, _) = decision else {
                return
            }

            let context = ModelContext(container)
            let deviceToken = try DeviceTokenStore.currentToken(in: context).token
            let readings = try queueStore.payloadReadings(for: batch.id).map {
                UploadReadingPayload(
                    lat: $0.latitude,
                    lng: $0.longitude,
                    roughnessRms: $0.roughnessRMS,
                    speedKmh: $0.speedKMH,
                    heading: $0.heading,
                    gpsAccuracyM: $0.gpsAccuracyM,
                    isPothole: $0.isPothole,
                    potholeMagnitude: $0.potholeMagnitude,
                    recordedAt: $0.recordedAt
                )
            }

            let summary = try await client.uploadReadings(
                batchID: batch.id,
                deviceToken: deviceToken,
                readings: readings
            )

            switch summary.result {
            case let .success(response):
                try queueStore.applySuccess(
                    batchID: batch.id,
                    result: UploadServerResult(
                        acceptedCount: response.accepted,
                        rejectedCount: response.rejected,
                        rejectedReasons: response.rejectedReasons,
                        wasDuplicateOnResubmit: response.duplicate
                    ),
                    now: now
                )
                logger.uploadSucceeded(batchID: batch.id, accepted: response.accepted, rejected: response.rejected, duplicate: response.duplicate)
            case let .failure(attemptResult, errorEnvelope):
                let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: batch.attemptCount + 1)
                try queueStore.applyFailure(
                    batchID: batch.id,
                    disposition: disposition,
                    errorMessage: errorEnvelope?.error ?? "upload_failed",
                    now: now
                )
                logger.uploadFailed(batchID: batch.id, attemptResult: attemptResult, message: errorEnvelope?.error)
            }
        } catch {
            logger.error("upload drain failed: \(error.localizedDescription)")
        }
    }
}
