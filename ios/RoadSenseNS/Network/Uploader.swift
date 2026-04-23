import Foundation
import SwiftData

private let uploaderNowProvider: @Sendable () -> Date = { Date() }

@MainActor
final class Uploader: UploadDrainPerforming {
    private let container: ModelContainer
    private let potholeActionStore: PotholeActionStore
    private let potholePhotoStore: PotholePhotoStore
    private let queueStore: UploadQueueStore
    private let client: APIClient
    private let logger: RoadSenseLogger

    init(
        container: ModelContainer,
        potholeActionStore: PotholeActionStore,
        potholePhotoStore: PotholePhotoStore,
        queueStore: UploadQueueStore,
        client: APIClient,
        logger: RoadSenseLogger
    ) {
        self.container = container
        self.potholeActionStore = potholeActionStore
        self.potholePhotoStore = potholePhotoStore
        self.queueStore = queueStore
        self.client = client
        self.logger = logger
    }

    func drainUntilBlocked(nowProvider: @escaping @Sendable () -> Date = uploaderNowProvider) async throws {
        while true {
            try Task.checkCancellation()

            let now = nowProvider()
            let readingDecision = try queueStore.prepareNextBatch(now: now)
            if case let .ready(batch, _) = readingDecision {
                try queueStore.markBatchInFlight(batchID: batch.id, now: now)
                let shouldContinue = try await uploadBatch(batch, nowProvider: nowProvider)
                guard shouldContinue else {
                    return
                }
                continue
            }

            let potholeDecision = try potholeActionStore.prepareNextAction(now: now)
            if case let .ready(action) = potholeDecision {
                let shouldContinue = try await uploadPotholeAction(action, nowProvider: nowProvider)
                guard shouldContinue else {
                    return
                }
                continue
            }

            let photoDecision = try potholePhotoStore.prepareNextReport(now: now)
            guard case let .ready(report) = photoDecision else {
                return
            }

            let shouldContinue = try await uploadPotholePhoto(report, nowProvider: nowProvider)
            guard shouldContinue else {
                return
            }
        }
    }

    func drainOnce(now: Date = Date()) async {
        do {
            try await drainUntilBlocked(nowProvider: { now })
        } catch {
            logger.error("upload drain failed: \(error.localizedDescription)")
        }
    }

    private func uploadBatch(
        _ batch: QueueUploadBatch,
        nowProvider: @escaping @Sendable () -> Date
    ) async throws -> Bool {
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

        let summary: UploadAttemptSummary
        do {
            summary = try await client.uploadReadings(
                batchID: batch.id,
                deviceToken: deviceToken,
                readings: readings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let now = nowProvider()
            let attemptResult = UploadAttemptResult.networkError
            let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: batch.attemptCount + 1)
            try queueStore.applyFailure(
                batchID: batch.id,
                disposition: disposition,
                errorMessage: error.localizedDescription,
                now: now
            )
            logger.uploadFailed(batchID: batch.id, attemptResult: attemptResult, message: error.localizedDescription)
            return false
        }

        let now = nowProvider()
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
            return true
        case let .failure(attemptResult, errorEnvelope):
            let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: batch.attemptCount + 1)
            try queueStore.applyFailure(
                batchID: batch.id,
                disposition: disposition,
                errorMessage: errorEnvelope?.error ?? "upload_failed",
                now: now
            )
            logger.uploadFailed(batchID: batch.id, attemptResult: attemptResult, message: errorEnvelope?.error)
            return false
        }
    }

    private func uploadPotholeAction(
        _ action: PotholeActionRecord,
        nowProvider: @escaping @Sendable () -> Date
    ) async throws -> Bool {
        let context = ModelContext(container)
        let deviceToken = try DeviceTokenStore.currentToken(in: context).token

        let summary: PotholeActionAttemptSummary
        do {
            summary = try await client.uploadPotholeAction(
                action: action,
                deviceToken: deviceToken,
                now: nowProvider()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let now = nowProvider()
            let attemptResult = UploadAttemptResult.networkError
            let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: action.uploadAttemptCount + 1)
            try potholeActionStore.applyUploadFailure(
                id: action.id,
                disposition: disposition,
                attemptResult: attemptResult,
                requestID: nil,
                now: now
            )
            logger.error("pothole_action_failed id=\(action.id.uuidString) result=\(String(describing: attemptResult)) message=\(error.localizedDescription)")
            return false
        }

        let now = nowProvider()
        switch summary.result {
        case .success:
            try potholeActionStore.applyUploadSuccess(id: action.id)
            logger.info("pothole_action_succeeded id=\(action.id.uuidString)")
            return true
        case let .failure(errorEnvelope):
            let attemptResult = UploadAttemptResult.http(
                statusCode: summary.statusCode,
                retryAfterSeconds: summary.retryAfterSeconds
            )
            let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: action.uploadAttemptCount + 1)
            try potholeActionStore.applyUploadFailure(
                id: action.id,
                disposition: disposition,
                attemptResult: attemptResult,
                requestID: summary.requestID,
                now: now
            )
            logger.error("pothole_action_failed id=\(action.id.uuidString) result=\(String(describing: attemptResult)) message=\(errorEnvelope?.error ?? "unknown")")
            return false
        }
    }

    private func uploadPotholePhoto(
        _ report: PotholeReportRecord,
        nowProvider: @escaping @Sendable () -> Date
    ) async throws -> Bool {
        let context = ModelContext(container)
        let deviceToken = try DeviceTokenStore.currentToken(in: context).token

        let metadataSummary: PotholePhotoMetadataAttemptSummary
        do {
            metadataSummary = try await client.beginPotholePhotoUpload(
                report: report,
                deviceToken: deviceToken,
                now: nowProvider()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let now = nowProvider()
            let attemptResult = UploadAttemptResult.networkError
            let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: report.uploadAttemptCount + 1)
            try potholePhotoStore.applyUploadFailure(
                id: report.id,
                disposition: disposition,
                attemptResult: attemptResult,
                requestID: nil,
                now: now
            )
            logger.error("pothole_photo_failed id=\(report.id.uuidString) result=\(String(describing: attemptResult)) message=\(error.localizedDescription)")
            return false
        }

        switch metadataSummary.result {
        case let .ready(response):
            let putSummary: SignedUploadAttemptSummary
            do {
                putSummary = try await client.uploadPotholePhotoFile(
                    fileURL: report.photoFileURL,
                    uploadURL: response.uploadURL,
                    sha256Hex: report.sha256Hex
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let now = nowProvider()
                let attemptResult = UploadAttemptResult.networkError
                let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: report.uploadAttemptCount + 1)
                try potholePhotoStore.applyUploadFailure(
                    id: report.id,
                    disposition: disposition,
                    attemptResult: attemptResult,
                    requestID: metadataSummary.requestID,
                    now: now
                )
                logger.error("pothole_photo_failed id=\(report.id.uuidString) result=\(String(describing: attemptResult)) message=\(error.localizedDescription)")
                return false
            }

            let now = nowProvider()
            switch putSummary.statusCode {
            case 200, 201, 204:
                try potholePhotoStore.applyUploadSuccess(
                    id: report.id,
                    expectedObjectPath: response.expectedObjectPath,
                    requestID: metadataSummary.requestID,
                    now: now
                )
                logger.info("pothole_photo_succeeded id=\(report.id.uuidString)")
                return true
            default:
                let attemptResult = UploadAttemptResult.http(statusCode: putSummary.statusCode, retryAfterSeconds: nil)
                let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: report.uploadAttemptCount + 1)
                try potholePhotoStore.applyUploadFailure(
                    id: report.id,
                    disposition: disposition,
                    attemptResult: attemptResult,
                    requestID: metadataSummary.requestID,
                    now: now
                )
                logger.error("pothole_photo_failed id=\(report.id.uuidString) result=\(String(describing: attemptResult)) message=put_failed")
                return false
            }
        case .alreadyUploaded:
            try potholePhotoStore.applyUploadSuccess(
                id: report.id,
                expectedObjectPath: report.expectedObjectPath,
                requestID: metadataSummary.requestID,
                now: nowProvider()
            )
            logger.info("pothole_photo_already_uploaded id=\(report.id.uuidString)")
            return true
        case let .failure(errorEnvelope):
            let attemptResult = UploadAttemptResult.http(
                statusCode: metadataSummary.statusCode,
                retryAfterSeconds: metadataSummary.retryAfterSeconds
            )
            let disposition = UploadPolicy.evaluate(attemptResult, attemptNumber: report.uploadAttemptCount + 1)
            try potholePhotoStore.applyUploadFailure(
                id: report.id,
                disposition: disposition,
                attemptResult: attemptResult,
                requestID: metadataSummary.requestID,
                now: nowProvider()
            )
            logger.error("pothole_photo_failed id=\(report.id.uuidString) result=\(String(describing: attemptResult)) message=\(errorEnvelope?.error ?? "unknown")")
            return false
        }
    }
}
