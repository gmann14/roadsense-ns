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
    private let networkPath: NetworkPathProviding?

    init(
        container: ModelContainer,
        potholeActionStore: PotholeActionStore,
        potholePhotoStore: PotholePhotoStore,
        queueStore: UploadQueueStore,
        client: APIClient,
        logger: RoadSenseLogger,
        networkPath: NetworkPathProviding? = nil
    ) {
        self.container = container
        self.potholeActionStore = potholeActionStore
        self.potholePhotoStore = potholePhotoStore
        self.queueStore = queueStore
        self.client = client
        self.logger = logger
        self.networkPath = networkPath
    }

    func drainUntilBlocked(nowProvider: @escaping @Sendable () -> Date = uploaderNowProvider) async throws {
        while true {
            try Task.checkCancellation()

            // Skip silently while offline so a doomed attempt does not burn
            // retry backoff (P0-6); the connectivity restorer drains again
            // once the path is satisfied.
            if let networkPath, networkPath.currentSnapshot.status != .satisfied {
                logger.info("upload drain skipped: network path unsatisfied")
                return
            }

            let now = nowProvider()
            let potholeDecision = try potholeActionStore.prepareNextAction(now: now)
            if case let .ready(action) = potholeDecision {
                let shouldContinue = try await uploadPotholeAction(action, nowProvider: nowProvider)
                guard shouldContinue else {
                    return
                }
                continue
            }

            let photoDecision = try potholePhotoStore.prepareNextReport(now: now)
            if case let .ready(report) = photoDecision {
                let shouldContinue = try await uploadPotholePhoto(report, nowProvider: nowProvider)
                guard shouldContinue else {
                    return
                }
                continue
            }

            let readingDecision = try queueStore.prepareNextBatch(now: now)
            guard case let .ready(batch, _) = readingDecision else {
                return
            }

            try queueStore.markBatchInFlight(batchID: batch.id, now: now)
            let shouldContinue = try await uploadBatch(batch, nowProvider: nowProvider)
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
                    uploadURL: response.uploadURL
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
            if errorEnvelope?.error == "photos_disabled" {
                // Expected while the server-side photo flow is disabled
                // pending its R2 bucket (review NEW-2) — the photo stays
                // queued and re-probes on the server's Retry-After cadence.
                logger.info("pothole_photo_deferred id=\(report.id.uuidString) photos_disabled retry_after=\(metadataSummary.retryAfterSeconds.map(String.init(describing:)) ?? "none")")
            } else {
                logger.error("pothole_photo_failed id=\(report.id.uuidString) result=\(String(describing: attemptResult)) message=\(errorEnvelope?.error ?? "unknown")")
            }
            return false
        }
    }
}
