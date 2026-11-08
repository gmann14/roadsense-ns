import Foundation
import CoreLocation
import SwiftData
import XCTest
@testable import RoadSense_NS

final class NetworkAndUploaderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAPIClientUploadsAndParsesSuccess() async throws {
        let session = makeMockSession()
        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let batchID = UUID()
        let deviceToken = "device-token"
        let reading = UploadReadingPayload(
            lat: 44.6488,
            lng: -63.5752,
            roughnessRms: 1.4,
            speedKmh: 52,
            heading: 180,
            gpsAccuracyM: 5,
            isPothole: false,
            potholeMagnitude: nil,
            recordedAt: Date(timeIntervalSince1970: 1_713_000_000)
        )
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/upload-readings")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer anon.test")
            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                UploadReadingsRequest.self,
                from: try requestBody(for: request)
            )
            XCTAssertEqual(payload.batchID, batchID)
            XCTAssertEqual(payload.deviceToken, deviceToken)
            XCTAssertFalse(payload.clientAppVersion.isEmpty)
            XCTAssertTrue(payload.clientOSVersion.hasPrefix("iOS "))
            XCTAssertEqual(payload.readings.count, 1)

            let encoder = UploadCodec.makeEncoder()
            let response = UploadReadingsResponse(
                batchID: payload.batchID,
                accepted: 1,
                rejected: 0,
                duplicate: false,
                rejectedReasons: [:]
            )
            let data = try encoder.encode(response)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                data
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let summary = try await client.uploadReadings(
            batchID: batchID,
            deviceToken: deviceToken,
            readings: [reading]
        )

        switch summary.result {
        case let .success(response):
            XCTAssertEqual(response.batchID, batchID)
            XCTAssertEqual(response.accepted, 1)
            XCTAssertEqual(response.rejected, 0)
            XCTAssertFalse(response.duplicate)
        case .failure:
            XCTFail("Expected successful upload response")
        }
    }

    func testAPIClientUploadsPotholeActionAndParsesSuccess() async throws {
        let session = makeMockSession()
        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let actionID = UUID()
        let potholeReportID = UUID()
        let recordedAt = Date(timeIntervalSince1970: 1_713_000_000)
        let requestNow = Date(timeIntervalSince1970: 1_713_000_100)
        let action = PotholeActionRecord(
            id: actionID,
            potholeReportID: potholeReportID,
            actionType: .confirmPresent,
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 5,
            recordedAt: recordedAt,
            createdAt: recordedAt,
            uploadState: .pendingUpload
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/pothole-actions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer anon.test")

            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                PotholeActionUploadRequest.self,
                from: try requestBody(for: request)
            )
            XCTAssertEqual(payload.actionID, actionID)
            XCTAssertEqual(payload.deviceToken, "device-token")
            XCTAssertEqual(payload.clientSentAt, requestNow)
            XCTAssertEqual(payload.actionType, PotholeActionType.confirmPresent.rawValue)
            XCTAssertEqual(payload.potholeReportID, potholeReportID)
            XCTAssertEqual(payload.lat, 44.6488, accuracy: 0.0001)
            XCTAssertEqual(payload.lng, -63.5752, accuracy: 0.0001)
            XCTAssertEqual(payload.accuracyM, 5, accuracy: 0.001)
            XCTAssertEqual(payload.recordedAt, recordedAt)
            XCTAssertNil(payload.sensorBackedMagnitudeG)
            XCTAssertNil(payload.sensorBackedAt)
            XCTAssertFalse(payload.clientAppVersion.isEmpty)
            XCTAssertTrue(payload.clientOSVersion.hasPrefix("iOS "))

            let encoder = UploadCodec.makeEncoder()
            let response = PotholeActionUploadResponse(
                actionID: payload.actionID,
                potholeReportID: potholeReportID,
                status: "accepted"
            )
            let data = try encoder.encode(response)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-123"]
                )!,
                data
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let summary = try await client.uploadPotholeAction(
            action: action,
            deviceToken: "device-token",
            now: requestNow
        )

        XCTAssertEqual(summary.statusCode, 200)
        XCTAssertEqual(summary.requestID, "req-123")
        XCTAssertNil(summary.retryAfterSeconds)

        switch summary.result {
        case let .success(response):
            XCTAssertEqual(response.actionID, actionID)
            XCTAssertEqual(response.potholeReportID, potholeReportID)
            XCTAssertEqual(response.status, "accepted")
        case .failure:
            XCTFail("Expected successful pothole action upload response")
        }
    }

    func testAPIClientBeginsPotholePhotoUploadAndParsesSuccess() async throws {
        let session = makeMockSession()
        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let reportID = UUID()
        let segmentID = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_713_000_000)
        let requestNow = Date(timeIntervalSince1970: 1_713_000_100)
        let report = PotholeReportRecord(
            id: reportID,
            segmentID: segmentID,
            photoFilePath: "/tmp/photo.jpg",
            latitude: 44.6488,
            longitude: -63.5752,
            accuracyM: 5,
            capturedAt: capturedAt,
            uploadState: .pendingMetadata,
            byteSize: 321_000,
            sha256Hex: String(repeating: "a", count: 64)
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/pothole-photos")

            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                PotholePhotoUploadRequest.self,
                from: try requestBody(for: request)
            )
            XCTAssertEqual(payload.reportID, reportID)
            XCTAssertEqual(payload.segmentID, segmentID)
            XCTAssertEqual(payload.deviceToken, "device-token")
            XCTAssertEqual(payload.clientSentAt, requestNow)
            XCTAssertEqual(payload.contentType, "image/jpeg")
            XCTAssertEqual(payload.byteSize, 321_000)
            XCTAssertEqual(payload.sha256, String(repeating: "a", count: 64))

            let encoder = UploadCodec.makeEncoder()
            let data = try encoder.encode(
                PotholePhotoUploadResponse(
                    reportID: reportID,
                    uploadURL: URL(string: "https://example.supabase.co/upload")!,
                    uploadExpiresAt: Date(timeIntervalSince1970: 1_713_007_300),
                    expectedObjectPath: "pending/\(reportID.uuidString.lowercased()).jpg"
                )
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-photo-1"]
                )!,
                data
            )
        }

        let client = APIClient(endpoints: endpoints, session: session)
        let summary = try await client.beginPotholePhotoUpload(
            report: report,
            deviceToken: "device-token",
            now: requestNow
        )

        XCTAssertEqual(summary.statusCode, 200)
        XCTAssertEqual(summary.requestID, "req-photo-1")
        switch summary.result {
        case let .ready(response):
            XCTAssertEqual(response.reportID, reportID)
            XCTAssertEqual(response.expectedObjectPath, "pending/\(reportID.uuidString.lowercased()).jpg")
        default:
            XCTFail("Expected ready response")
        }
    }

    // Regression test for the P0 fix: DeviceTokenStore.currentToken used to
    // insert a DeviceTokenRecord into the caller's ModelContext without
    // calling save(), so the record never reached disk. Every Uploader call
    // site creates its own throwaway ModelContext(container) with autosave
    // off, so a missing save meant every upload minted a brand new random
    // token — breaking server-side dedupe and the two-device pothole
    // corroboration gate. This test simulates that exact scenario: two
    // separate ModelContext instances backed by the same container, as if
    // two separate upload calls each grabbed their own throwaway context.
    @MainActor
    func testDeviceTokenStorePersistsTokenAcrossSeparateModelContexts() throws {
        let container = try makeInMemoryContainer()
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let firstContext = ModelContext(container)
        let firstToken = try DeviceTokenStore.currentToken(
            in: firstContext,
            now: now,
            makeUUID: { "first-call-token" }
        )

        let secondContext = ModelContext(container)
        let secondToken = try DeviceTokenStore.currentToken(
            in: secondContext,
            now: now.addingTimeInterval(5),
            makeUUID: { "second-call-token" }
        )

        XCTAssertEqual(firstToken.token, "first-call-token")
        XCTAssertEqual(
            secondToken.token,
            "first-call-token",
            "the token minted by the first context must have been persisted and reused by the second"
        )
        XCTAssertEqual(secondToken.issuedAt, firstToken.issuedAt)

        // A third, independent context must also see exactly one persisted
        // record — proving the insert was actually saved to the container's
        // backing store rather than living only in an in-memory context.
        let thirdContext = ModelContext(container)
        let allTokens = try thirdContext.fetch(FetchDescriptor<DeviceTokenRecord>())
        XCTAssertEqual(allTokens.count, 1)
        XCTAssertEqual(allTokens.first?.token, "first-call-token")
    }

    @MainActor
    func testUploaderDrainOnceMarksBatchSucceeded() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let readingID = UUID()
        let token = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )
        XCTAssertEqual(token.token, "device-token")

        context.insert(
            ReadingRecord(
                id: readingID,
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.6,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: true,
                potholeMagnitude: 3.2,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                UploadReadingsRequest.self,
                from: try requestBody(for: request)
            )
            let encoder = UploadCodec.makeEncoder()
            let data = try encoder.encode(
                UploadReadingsResponse(
                    batchID: payload.batchID,
                    accepted: 1,
                    rejected: 0,
                    duplicate: false,
                    rejectedReasons: [:]
                )
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                data
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let now = Date(timeIntervalSince1970: 1_713_000_100)
        await uploader.drainOnce(now: now)

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(FetchDescriptor<ReadingRecord>())
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(readings.first?.id, readingID)
        XCTAssertEqual(readings.first?.uploadedAt, now)
        XCTAssertEqual(batches.first?.status, .succeeded)
        XCTAssertEqual(batches.first?.acceptedCount, 1)
        XCTAssertEqual(batches.first?.rejectedCount, 0)
        XCTAssertFalse(batches.first?.wasDuplicateOnResubmit ?? true)
    }

    @MainActor
    func testUploaderDrainPrioritizesPotholeActionsBeforeReadingBatches() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        let actionID = UUID()
        context.insert(
            PotholeActionRecord(
                id: actionID,
                actionType: .manualReport,
                latitude: 44.6488,
                longitude: -63.5752,
                accuracyM: 4,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010),
                createdAt: Date(timeIntervalSince1970: 1_713_000_011),
                uploadState: .pendingUpload,
                sensorBackedMagnitudeG: 2.6,
                sensorBackedAt: Date(timeIntervalSince1970: 1_713_000_008)
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.6,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_012)
            )
        )
        try context.save()

        let session = makeMockSession()
        var requestPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            requestPaths.append(request.url?.path ?? "")
            let encoder = UploadCodec.makeEncoder()

            if request.url?.path == "/functions/v1/pothole-actions" {
                let decoder = UploadCodec.makeDecoder()
                let payload = try decoder.decode(
                    PotholeActionUploadRequest.self,
                    from: try requestBody(for: request)
                )
                XCTAssertEqual(payload.actionID, actionID)
                let data = try encoder.encode(
                    PotholeActionUploadResponse(
                        actionID: payload.actionID,
                        potholeReportID: UUID(),
                        status: "accepted"
                    )
                )
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["x-request-id": "req-pothole-priority"]
                    )!,
                    data
                )
            }

            XCTAssertEqual(request.url?.path, "/functions/v1/upload-readings")
            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                UploadReadingsRequest.self,
                from: try requestBody(for: request)
            )
            let data = try encoder.encode(
                UploadReadingsResponse(
                    batchID: payload.batchID,
                    accepted: 1,
                    rejected: 0,
                    duplicate: false,
                    rejectedReasons: [:]
                )
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                data
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        try await uploader.drainUntilBlocked(nowProvider: { Date(timeIntervalSince1970: 1_713_000_100) })

        XCTAssertEqual(requestPaths, ["/functions/v1/pothole-actions", "/functions/v1/upload-readings"])
    }

    @MainActor
    func testUploaderDrainOnceLeavesBatchPendingAfterRateLimit() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.1,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            let encoder = UploadCodec.makeEncoder()
            let data = try encoder.encode(
                UploadErrorEnvelope(
                    error: "rate_limited",
                    details: ["retry_after": "7"]
                )
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "7"]
                )!,
                data
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let now = Date(timeIntervalSince1970: 1_713_000_100)
        await uploader.drainOnce(now: now)

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(FetchDescriptor<ReadingRecord>())
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(readings.count, 1)
        XCTAssertNil(readings.first?.uploadedAt)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.status, .pending)
        XCTAssertEqual(batches.first?.attemptCount, 1)
        XCTAssertEqual(batches.first?.firstErrorMessage, "rate_limited")
        XCTAssertEqual(
            batches.first?.nextAttemptAt,
            now.addingTimeInterval(7)
        )
    }

    @MainActor
    func testUploaderDrainOncePersistsBackoffAfterNetworkError() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.1,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let now = Date(timeIntervalSince1970: 1_713_000_100)
        await uploader.drainOnce(now: now)

        let updatedContext = ModelContext(container)
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.status, .pending)
        XCTAssertEqual(batches.first?.attemptCount, 1)
        XCTAssertEqual(batches.first?.firstErrorMessage, URLError(.notConnectedToInternet).localizedDescription)
        XCTAssertEqual(batches.first?.nextAttemptAt, now.addingTimeInterval(1))
    }

    // Regression test for P1-i1 (docs/reviews/2026-07-02-full-codebase-review.md):
    // a cancelled URLSession call surfaces as URLError(.cancelled), not
    // CancellationError, from URLSession.data(for:). Before the fix, only
    // `catch is CancellationError` was special-cased, so a background-task
    // expiration mid-upload fell into the generic network-error path,
    // recording a failed attempt and inflating exponential backoff (up to
    // 1h) for what was really just the OS reclaiming background time — not a
    // real network failure. This asserts URLError(.cancelled) is treated the
    // same as CancellationError: no attempt recorded, no backoff applied,
    // batch left exactly as markBatchInFlight left it.
    @MainActor
    func testUploaderDrainTreatsURLErrorCancelledAsCancellationNotFailure() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.1,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let now = Date(timeIntervalSince1970: 1_713_000_100)
        // drainOnce swallows the rethrown CancellationError at the top level
        // (see Uploader.drainOnce's catch-and-log), so this must not throw
        // and must not hang.
        await uploader.drainOnce(now: now)

        let updatedContext = ModelContext(container)
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(batches.count, 1)
        // markBatchInFlight ran before the request; applyFailure must NOT
        // have run afterward, so the batch stays inFlight with zero attempts
        // recorded and no backoff/error message written — proving the
        // cancellation path was taken instead of the network-error path.
        XCTAssertEqual(batches.first?.status, .inFlight)
        XCTAssertEqual(batches.first?.attemptCount, 0)
        XCTAssertNil(batches.first?.firstErrorMessage)
        XCTAssertNil(batches.first?.nextAttemptAt)
    }

    // Regression tests for P0-6 (docs/reviews/2026-06-11-ios-prelaunch-review.md):
    // offline drains used to burn retry attempts until the batch permanently
    // failed behind a manual retry button.
    @MainActor
    func testUploaderSkipsDrainWithoutCountingAttemptsWhileOffline() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.1,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { _ in
            XCTFail("No request expected while the network path is unsatisfied")
            throw URLError(.notConnectedToInternet)
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload,
            networkPath: StubNetworkPath(
                snapshot: NetworkPathSnapshot(status: .unsatisfied, isExpensive: false)
            )
        )

        // Five offline drains used to be enough to permanently fail a batch.
        for offset in 0..<5 {
            await uploader.drainOnce(now: Date(timeIntervalSince1970: 1_713_000_100 + Double(offset) * 60))
        }

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(FetchDescriptor<ReadingRecord>())
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertTrue(batches.isEmpty, "offline drains must not create or fail batches")
        XCTAssertNil(readings.first?.uploadBatchID)
        XCTAssertNil(readings.first?.uploadedAt)
    }

    @MainActor
    func testUploaderDrainOnceMarksBatchFailedPermanentOnValidationError() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.1,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            let encoder = UploadCodec.makeEncoder()
            let data = try encoder.encode(
                UploadErrorEnvelope(error: "validation_failed", details: nil)
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                data
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        await uploader.drainOnce(now: Date(timeIntervalSince1970: 1_713_000_100))

        let updatedContext = ModelContext(container)
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.status, .failedPermanent)
        XCTAssertEqual(batches.first?.firstErrorMessage, "validation_failed")
    }

    @MainActor
    func testNetworkRestoreRequeuesBatchesAndRequestsDrain() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let networkFailed = UploadBatch(
            createdAt: Date(timeIntervalSince1970: 1_713_000_000),
            attemptCount: 3,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_030),
            nextAttemptAt: nil,
            status: .pending,
            readingCount: 10,
            firstErrorMessage: "network_error"
        )
        let serverThrottled = UploadBatch(
            createdAt: Date(timeIntervalSince1970: 1_713_000_000),
            attemptCount: 1,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_030),
            nextAttemptAt: nil,
            status: .pending,
            readingCount: 8,
            firstErrorMessage: "service_unavailable"
        )
        let permanentlyFailed = UploadBatch(
            createdAt: Date(timeIntervalSince1970: 1_713_000_000),
            attemptCount: 1,
            lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_030),
            nextAttemptAt: nil,
            status: .failedPermanent,
            readingCount: 5,
            firstErrorMessage: "validation_failed"
        )
        context.insert(networkFailed)
        context.insert(serverThrottled)
        context.insert(permanentlyFailed)
        try context.save()
        let networkFailedID = networkFailed.id
        let serverThrottledID = serverThrottled.id
        let permanentlyFailedID = permanentlyFailed.id

        let queueStore = UploadQueueStore(container: container)
        let failureTime = Date(timeIntervalSince1970: 1_713_000_060)
        try queueStore.applyFailure(
            batchID: networkFailedID,
            disposition: .retry(afterSeconds: 3_600),
            errorMessage: "offline",
            attemptResult: .networkError,
            now: failureTime
        )
        try queueStore.applyFailure(
            batchID: serverThrottledID,
            disposition: .retry(afterSeconds: 3_600),
            errorMessage: "service_unavailable",
            attemptResult: .http(statusCode: 503, retryAfterSeconds: 3_600),
            now: failureTime
        )

        let drainCoordinator = RecordingDrainCoordinator()
        let restorer = UploadConnectivityRestorer(
            queueStore: queueStore,
            drainCoordinator: drainCoordinator,
            logger: .upload
        )

        await restorer.handleNetworkRestored()

        let updatedContext = ModelContext(container)
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())
        let restored = try XCTUnwrap(batches.first(where: { $0.id == networkFailedID }))
        let throttled = try XCTUnwrap(batches.first(where: { $0.id == serverThrottledID }))
        let failed = try XCTUnwrap(batches.first(where: { $0.id == permanentlyFailedID }))

        XCTAssertNil(restored.nextAttemptAt, "backoff accumulated offline must be cleared on restore")
        XCTAssertEqual(restored.attemptCount, 4)
        XCTAssertEqual(
            throttled.nextAttemptAt,
            failureTime.addingTimeInterval(3_600),
            "a server-requested backoff (429/5xx) is not a connectivity problem and must be honoured"
        )
        XCTAssertEqual(failed.status, .failedPermanent, "server-rejected batches stay behind the manual retry button")
        XCTAssertEqual(drainCoordinator.requestedReasons, [.networkRestored])
    }

    @MainActor
    func testNetworkRestoreLeavesBackoffAloneAfterLaterHTTPFailure() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let batch = UploadBatch(
            createdAt: Date(timeIntervalSince1970: 1_713_000_000),
            attemptCount: 0,
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            status: .pending,
            readingCount: 10,
            firstErrorMessage: nil
        )
        context.insert(batch)
        try context.save()
        let batchID = batch.id

        let queueStore = UploadQueueStore(container: container)
        let now = Date(timeIntervalSince1970: 1_713_000_060)
        try queueStore.applyFailure(
            batchID: batchID,
            disposition: .retry(afterSeconds: 60),
            errorMessage: "offline",
            attemptResult: .networkError,
            now: now
        )
        try queueStore.applyFailure(
            batchID: batchID,
            disposition: .retry(afterSeconds: 600),
            errorMessage: "rate_limited",
            attemptResult: .http(statusCode: 429, retryAfterSeconds: 600),
            now: now
        )

        try queueStore.requeueEligibleBatches()

        let stored = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<UploadBatch>()).first(where: { $0.id == batchID })
        )
        XCTAssertEqual(stored.nextAttemptAt, now.addingTimeInterval(600))
    }

    @MainActor
    func testUploaderDrainUntilBlockedProcessesMultipleBatchesUntilBackoff() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        for offset in 0..<1_200 {
            context.insert(
                ReadingRecord(
                    latitude: 44.6488,
                    longitude: -63.5752,
                    roughnessRMS: 0.9,
                    speedKMH: 45,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: false,
                    potholeMagnitude: nil,
                    recordedAt: Date(timeIntervalSince1970: 1_713_000_000 + Double(offset))
                )
            )
        }
        try context.save()

        let session = makeMockSession()
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                UploadReadingsRequest.self,
                from: try requestBody(for: request)
            )
            let encoder = UploadCodec.makeEncoder()

            if requestCount == 1 {
                let data = try encoder.encode(
                    UploadReadingsResponse(
                        batchID: payload.batchID,
                        accepted: payload.readings.count,
                        rejected: 0,
                        duplicate: false,
                        rejectedReasons: [:]
                    )
                )
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [:]
                    )!,
                    data
                )
            }

            let data = try encoder.encode(
                UploadErrorEnvelope(
                    error: "rate_limited",
                    details: ["retry_after": "60"]
                )
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "60"]
                )!,
                data
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let base = Date(timeIntervalSince1970: 1_713_000_100)
        let clock = LockedTickClock(base: base)
        try await uploader.drainUntilBlocked(nowProvider: {
            clock.next()
        })

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(FetchDescriptor<ReadingRecord>())
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(readings.filter { $0.uploadedAt != nil }.count, UploadQueueCore.maxReadingsPerBatch)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.filter { $0.status == .succeeded }.count, 1)
        XCTAssertEqual(batches.filter { $0.status == .pending }.count, 1)
        XCTAssertEqual(
            batches.first(where: { $0.status == .pending })?.nextAttemptAt,
            base.addingTimeInterval(63)
        )
    }

    @MainActor
    func testRetryFailedBatchesResetsPermanentFailures() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(
            UploadBatch(
                createdAt: Date(timeIntervalSince1970: 1_713_000_000),
                attemptCount: 5,
                lastAttemptAt: Date(timeIntervalSince1970: 1_713_000_060),
                nextAttemptAt: Date(timeIntervalSince1970: 1_713_000_120),
                status: .failedPermanent,
                readingCount: 10,
                firstErrorMessage: "upload_failed"
            )
        )
        try context.save()

        let store = UploadQueueStore(container: container)
        try store.retryFailedBatches()

        let updatedContext = ModelContext(container)
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.status, .pending)
        XCTAssertEqual(batches.first?.attemptCount, 0)
        XCTAssertNil(batches.first?.lastAttemptAt)
        XCTAssertNil(batches.first?.nextAttemptAt)
        XCTAssertNil(batches.first?.firstErrorMessage)
    }

    @MainActor
    func testUserStatsSummaryGroupsFragmentedDriveSessionsAsTrips() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let thirdSessionID = UUID()

        context.insert(
            DriveSessionRecord(
                id: firstSessionID,
                startedAt: Date(timeIntervalSince1970: 1_713_000_000),
                endedAt: Date(timeIntervalSince1970: 1_713_000_120),
                startLatitude: 44.6488,
                startLongitude: -63.5752,
                endLatitude: 44.6498,
                endLongitude: -63.5762,
                isSealed: true
            )
        )
        context.insert(
            DriveSessionRecord(
                id: secondSessionID,
                startedAt: Date(timeIntervalSince1970: 1_713_000_150),
                endedAt: Date(timeIntervalSince1970: 1_713_000_300),
                startLatitude: 44.6498,
                startLongitude: -63.5762,
                endLatitude: 44.6508,
                endLongitude: -63.5772,
                isSealed: true
            )
        )
        context.insert(
            DriveSessionRecord(
                id: thirdSessionID,
                startedAt: Date(timeIntervalSince1970: 1_713_001_000),
                endedAt: Date(timeIntervalSince1970: 1_713_001_180),
                startLatitude: 44.6600,
                startLongitude: -63.5865,
                endLatitude: 44.6610,
                endLongitude: -63.5875,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 0.06,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_060),
                driveSessionID: firstSessionID,
                uploadReadyAt: Date(timeIntervalSince1970: 1_713_000_400)
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6600,
                longitude: -63.5865,
                roughnessRMS: 0.11,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_001_060),
                driveSessionID: thirdSessionID,
                uploadReadyAt: Date(timeIntervalSince1970: 1_713_001_400)
            )
        )
        try context.save()

        let summary = try UserStatsStore(container: container).summary()

        XCTAssertEqual(summary.totalTripsRecorded, 2)
        XCTAssertEqual(summary.pendingTripUploadCount, 2)
        XCTAssertEqual(summary.pendingUploadCount, 2)
    }

    @MainActor
    func testReadingStorePendingUploadCoordinatesReturnsOrderedUnuploadedReadings() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let baseTime = Date(timeIntervalSince1970: 1_713_000_000)

        context.insert(
            ReadingRecord(
                latitude: 44.6484,
                longitude: -63.5754,
                roughnessRMS: 0.9,
                speedKMH: 42,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: baseTime.addingTimeInterval(30),
                droppedByPrivacyZone: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6486,
                longitude: -63.5753,
                roughnessRMS: 1.0,
                speedKMH: 44,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: baseTime.addingTimeInterval(20),
                uploadedAt: baseTime.addingTimeInterval(120)
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.1,
                speedKMH: 46,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: baseTime
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6490,
                longitude: -63.5751,
                roughnessRMS: 1.2,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: baseTime.addingTimeInterval(10)
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        let coordinates = try store.pendingUploadCoordinates()

        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(
            coordinates.map { [$0.latitude, $0.longitude] },
            [
                [44.6488, -63.5752],
                [44.6490, -63.5751],
            ]
        )
    }

    @MainActor
    func testReadingStoreHidesActiveDriveSessionRowsUntilSessionIsSealed() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)

        context.insert(
            DriveSessionRecord(
                id: sessionID,
                startedAt: startedAt,
                startLatitude: 44.6488,
                startLongitude: -63.5752
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6800,
                longitude: -63.6000,
                roughnessRMS: 1.1,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_300),
                driveSessionID: sessionID
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        XCTAssertTrue(try store.pendingUploadCoordinates().isEmpty)

        let summary = try store.finalizeDriveSession(
            id: sessionID,
            fallbackEndSample: LocationSample(
                timestamp: 1_600,
                latitude: 44.7090,
                longitude: -63.6220,
                horizontalAccuracyMeters: 5,
                speedKmh: 0,
                headingDegrees: 180
            ),
            now: Date(timeIntervalSince1970: 1_700)
        )

        XCTAssertEqual(summary?.eligibleReadingCount, 1)
        XCTAssertEqual(summary?.trimmedReadingCount, 0)
        XCTAssertEqual(
            try store.pendingUploadCoordinates().map { [$0.latitude, $0.longitude] },
            [[44.6800, -63.6000]]
        )
    }

    @MainActor
    func testReadingStoreFinalizeDriveSessionTrimsEndpointReadingsAndKeepsMiddle() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)

        context.insert(
            DriveSessionRecord(
                id: sessionID,
                startedAt: startedAt,
                startLatitude: 44.6488,
                startLongitude: -63.5752
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6490,
                longitude: -63.5751,
                roughnessRMS: 0.9,
                speedKMH: 42,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_030),
                driveSessionID: sessionID
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6800,
                longitude: -63.6000,
                roughnessRMS: 1.1,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_300),
                driveSessionID: sessionID
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.7088,
                longitude: -63.6219,
                roughnessRMS: 1.0,
                speedKMH: 40,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_580),
                driveSessionID: sessionID
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6500,
                longitude: -63.5750,
                roughnessRMS: 0,
                speedKMH: 15,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_020),
                driveSessionID: sessionID,
                droppedByPrivacyZone: true
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        let sealedAt = Date(timeIntervalSince1970: 1_700)
        let summary = try XCTUnwrap(
            try store.finalizeDriveSession(
                id: sessionID,
                fallbackEndSample: LocationSample(
                    timestamp: 1_600,
                    latitude: 44.7090,
                    longitude: -63.6220,
                    horizontalAccuracyMeters: 5,
                    speedKmh: 0,
                    headingDegrees: 180
                ),
                now: sealedAt
            )
        )

        XCTAssertEqual(summary.eligibleReadingCount, 1)
        XCTAssertEqual(summary.trimmedReadingCount, 2)
        XCTAssertEqual(summary.privacyFilteredReadingCount, 1)

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(
            FetchDescriptor<ReadingRecord>(
                predicate: #Predicate { $0.driveSessionID == sessionID },
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
            )
        )
        let readingsByTimestamp = Dictionary(uniqueKeysWithValues: readings.map {
            ($0.recordedAt.timeIntervalSince1970, $0)
        })

        XCTAssertEqual(readings.count, 4)
        XCTAssertNotNil(readingsByTimestamp[1_030]?.endpointTrimmedAt)
        XCTAssertNil(readingsByTimestamp[1_030]?.uploadReadyAt)
        XCTAssertNil(readingsByTimestamp[1_300]?.endpointTrimmedAt)
        XCTAssertEqual(readingsByTimestamp[1_300]?.uploadReadyAt, sealedAt)
        XCTAssertNotNil(readingsByTimestamp[1_580]?.endpointTrimmedAt)
        XCTAssertNil(readingsByTimestamp[1_580]?.uploadReadyAt)
        XCTAssertNil(readingsByTimestamp[1_020]?.endpointTrimmedAt)
        XCTAssertNil(readingsByTimestamp[1_020]?.uploadReadyAt)

        let coordinates = try store.pendingUploadCoordinates()
        XCTAssertEqual(
            coordinates.map { [$0.latitude, $0.longitude] },
            [[44.6800, -63.6000]]
        )
    }

    @MainActor
    func testReadingStoreFinalizeOpenDriveSessionsKeepsShortDrivePrivate() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()

        context.insert(
            DriveSessionRecord(
                id: sessionID,
                startedAt: Date(timeIntervalSince1970: 2_000),
                startLatitude: 44.6488,
                startLongitude: -63.5752
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6490,
                longitude: -63.5751,
                roughnessRMS: 1.0,
                speedKMH: 35,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 2_030),
                driveSessionID: sessionID
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6502,
                longitude: -63.5747,
                roughnessRMS: 1.1,
                speedKMH: 36,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 2_070),
                driveSessionID: sessionID
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        let summaries = try store.finalizeOpenDriveSessions(now: Date(timeIntervalSince1970: 2_120))

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.sessionID, sessionID)
        XCTAssertEqual(summaries.first?.eligibleReadingCount, 0)
        XCTAssertEqual(summaries.first?.trimmedReadingCount, 2)
        XCTAssertTrue(try store.pendingUploadCoordinates().isEmpty)
    }

    @MainActor
    func testReadingStoreRepairFragmentedDriveSessionsRecoversMergedDriveMiddle() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let trimmedAt = Date(timeIntervalSince1970: 2_000)
        let repairedAt = Date(timeIntervalSince1970: 2_500)

        let session1 = UUID()
        context.insert(
            DriveSessionRecord(
                id: session1,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_060),
                startLatitude: 44.6488,
                startLongitude: -63.5752,
                endLatitude: 44.6555,
                endLongitude: -63.5820,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6490,
                longitude: -63.5753,
                roughnessRMS: 1.0,
                speedKMH: 42,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_030),
                driveSessionID: session1,
                endpointTrimmedAt: trimmedAt
            )
        )

        let session2 = UUID()
        context.insert(
            DriveSessionRecord(
                id: session2,
                startedAt: Date(timeIntervalSince1970: 1_065),
                endedAt: Date(timeIntervalSince1970: 1_125),
                startLatitude: 44.6557,
                startLongitude: -63.5822,
                endLatitude: 44.6648,
                endLongitude: -63.5915,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6600,
                longitude: -63.5865,
                roughnessRMS: 1.1,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_085),
                driveSessionID: session2,
                endpointTrimmedAt: trimmedAt
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6625,
                longitude: -63.5892,
                roughnessRMS: 1.2,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_100),
                driveSessionID: session2,
                endpointTrimmedAt: trimmedAt
            )
        )

        let session3 = UUID()
        context.insert(
            DriveSessionRecord(
                id: session3,
                startedAt: Date(timeIntervalSince1970: 1_130),
                endedAt: Date(timeIntervalSince1970: 1_190),
                startLatitude: 44.6649,
                startLongitude: -63.5916,
                endLatitude: 44.6718,
                endLongitude: -63.5988,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6716,
                longitude: -63.5986,
                roughnessRMS: 0.9,
                speedKMH: 39,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_160),
                driveSessionID: session3,
                endpointTrimmedAt: trimmedAt
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        let summary = try store.repairFragmentedDriveSessions(
            now: repairedAt,
            maximumGapSeconds: 10
        )

        XCTAssertEqual(summary.fragmentedGroupCount, 1)
        XCTAssertEqual(summary.recoveredEligibleReadingCount, 2)
        XCTAssertEqual(summary.eligibleReadingCount, 2)
        XCTAssertEqual(summary.trimmedReadingCount, 2)

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(
            FetchDescriptor<ReadingRecord>(
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)]
            )
        )
        let readingsByTimestamp = Dictionary(uniqueKeysWithValues: readings.map {
            ($0.recordedAt.timeIntervalSince1970, $0)
        })

        XCTAssertNotNil(readingsByTimestamp[1_030]?.endpointTrimmedAt)
        XCTAssertNil(readingsByTimestamp[1_030]?.uploadReadyAt)
        XCTAssertNil(readingsByTimestamp[1_085]?.endpointTrimmedAt)
        XCTAssertEqual(readingsByTimestamp[1_085]?.uploadReadyAt, repairedAt)
        XCTAssertNil(readingsByTimestamp[1_100]?.endpointTrimmedAt)
        XCTAssertEqual(readingsByTimestamp[1_100]?.uploadReadyAt, repairedAt)
        XCTAssertNotNil(readingsByTimestamp[1_160]?.endpointTrimmedAt)
        XCTAssertNil(readingsByTimestamp[1_160]?.uploadReadyAt)

        let coordinates = try store.pendingUploadCoordinates()
        XCTAssertEqual(
            coordinates.map { [$0.latitude, $0.longitude] },
            [
                [44.6600, -63.5865],
                [44.6625, -63.5892]
            ]
        )
    }

    // Regression test for the P1 fix: repairFragmentedDriveSessions used to
    // null out uploadBatchID for every non-uploaded reading in a fragmented
    // group, including readings already assigned to a pending/inFlight
    // UploadBatch. That races a suspended drain — if the server responds 200
    // after repair clears the ID, UploadQueueStore.applySuccess (which looks
    // readings up by uploadBatchID) finds nothing to mark uploaded, so the
    // reading silently gets re-batched and re-uploaded (duplication). This
    // test asserts readings tied to a non-terminal batch are left untouched
    // by repair while other eligible readings in the same fragmented group
    // are still recovered normally.
    @MainActor
    func testReadingStoreRepairFragmentedDriveSessionsSkipsReadingsInNonTerminalBatch() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let trimmedAt = Date(timeIntervalSince1970: 2_000)
        let repairedAt = Date(timeIntervalSince1970: 2_500)

        let session1 = UUID()
        context.insert(
            DriveSessionRecord(
                id: session1,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_060),
                startLatitude: 44.6488,
                startLongitude: -63.5752,
                endLatitude: 44.6555,
                endLongitude: -63.5820,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6490,
                longitude: -63.5753,
                roughnessRMS: 1.0,
                speedKMH: 42,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_030),
                driveSessionID: session1,
                endpointTrimmedAt: trimmedAt
            )
        )

        let session2 = UUID()
        context.insert(
            DriveSessionRecord(
                id: session2,
                startedAt: Date(timeIntervalSince1970: 1_065),
                endedAt: Date(timeIntervalSince1970: 1_125),
                startLatitude: 44.6557,
                startLongitude: -63.5822,
                endLatitude: 44.6648,
                endLongitude: -63.5915,
                isSealed: true
            )
        )

        // This reading is in the recoverable "eligible middle" window, but it
        // is already assigned to an in-flight batch — repair must leave it
        // completely untouched.
        let inFlightBatchID = UUID()
        context.insert(
            UploadBatch(
                id: inFlightBatchID,
                createdAt: Date(timeIntervalSince1970: 1_900),
                status: .inFlight,
                readingCount: 1
            )
        )
        let inFlightReadingID = UUID()
        context.insert(
            ReadingRecord(
                id: inFlightReadingID,
                latitude: 44.6600,
                longitude: -63.5865,
                roughnessRMS: 1.1,
                speedKMH: 48,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_085),
                driveSessionID: session2,
                uploadBatchID: inFlightBatchID,
                endpointTrimmedAt: trimmedAt
            )
        )

        // This reading is in the same eligible window but has no batch
        // assignment — repair should recover it as usual.
        context.insert(
            ReadingRecord(
                latitude: 44.6625,
                longitude: -63.5892,
                roughnessRMS: 1.2,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_100),
                driveSessionID: session2,
                endpointTrimmedAt: trimmedAt
            )
        )

        let session3 = UUID()
        context.insert(
            DriveSessionRecord(
                id: session3,
                startedAt: Date(timeIntervalSince1970: 1_130),
                endedAt: Date(timeIntervalSince1970: 1_190),
                startLatitude: 44.6649,
                startLongitude: -63.5916,
                endLatitude: 44.6718,
                endLongitude: -63.5988,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6716,
                longitude: -63.5986,
                roughnessRMS: 0.9,
                speedKMH: 39,
                heading: 180,
                gpsAccuracyM: 4,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_160),
                driveSessionID: session3,
                endpointTrimmedAt: trimmedAt
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        let summary = try store.repairFragmentedDriveSessions(
            now: repairedAt,
            maximumGapSeconds: 10
        )

        // Only the untouched reading (44.6625) counts toward eligible/recovered;
        // the in-flight reading is skipped entirely and must not be counted.
        XCTAssertEqual(summary.fragmentedGroupCount, 1)
        XCTAssertEqual(summary.recoveredEligibleReadingCount, 1)
        XCTAssertEqual(summary.eligibleReadingCount, 1)
        XCTAssertEqual(summary.trimmedReadingCount, 2)

        let updatedContext = ModelContext(container)
        let inFlightReading = try XCTUnwrap(
            try updatedContext.fetch(
                FetchDescriptor<ReadingRecord>(
                    predicate: #Predicate { $0.id == inFlightReadingID }
                )
            ).first
        )

        // Untouched: still trimmed, still tied to the in-flight batch, no
        // uploadReadyAt — repair must not have mutated this reading at all.
        XCTAssertEqual(inFlightReading.endpointTrimmedAt, trimmedAt)
        XCTAssertNil(inFlightReading.uploadReadyAt)
        XCTAssertEqual(inFlightReading.uploadBatchID, inFlightBatchID)

        let recoveredReading = try XCTUnwrap(
            try updatedContext.fetch(
                FetchDescriptor<ReadingRecord>(
                    predicate: #Predicate { $0.latitude == 44.6625 }
                )
            ).first
        )
        XCTAssertNil(recoveredReading.endpointTrimmedAt)
        XCTAssertEqual(recoveredReading.uploadReadyAt, repairedAt)
        XCTAssertNil(recoveredReading.uploadBatchID)

        // The in-flight reading must not appear in pendingUploadCoordinates
        // either, since it still carries a live uploadBatchID... but that
        // query only filters on uploadedAt, so assert directly on the model
        // above is the authoritative check. This also confirms the batch
        // itself is untouched by repair.
        let batch = try XCTUnwrap(
            try updatedContext.fetch(
                FetchDescriptor<UploadBatch>(
                    predicate: #Predicate { $0.id == inFlightBatchID }
                )
            ).first
        )
        XCTAssertEqual(batch.status, .inFlight)
    }

    @MainActor
    func testSensorCoordinatorIgnoresBriefDrivingFalseBlip() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            stopCollectionGracePeriod: .milliseconds(50),
            scheduleUploadDrain: { _ in }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))

        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(locationService.startCount, 1)

        drivingDetector.send(false)
        try? await Task.sleep(for: .milliseconds(20))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(70))

        XCTAssertTrue(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(locationService.startCount, 1)
        XCTAssertEqual(locationService.stopCount, 0)
        XCTAssertEqual(motionService.startCount, 1)
        XCTAssertEqual(motionService.stopCount, 0)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testSensorCoordinatorArmsPassiveLocationMonitoring() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: CountingMotionService(),
            drivingDetector: StreamDrivingDetector(),
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(locationService.passiveStartCount, 1)
        XCTAssertEqual(locationService.startCount, 0)

        coordinator.stopMonitoring()
        XCTAssertEqual(locationService.passiveStopCount, 1)
        try? checkpointStore.clear()
    }

    @MainActor
    func testSensorCoordinatorIgnoresCyclingSpeedLocationBootstrap() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: StreamDrivingDetector(),
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        locationService.send(
            LocationSample(
                timestamp: 1_713_000_000,
                latitude: 44.6488,
                longitude: -63.5752,
                horizontalAccuracyMeters: 12,
                speedKmh: 42,
                headingDegrees: 180
            )
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(locationService.startCount, 0)
        XCTAssertEqual(motionService.startCount, 0)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testSensorCoordinatorStartsCollectionFromHighSpeedLocationBootstrap() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: StreamDrivingDetector(),
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        locationService.send(
            LocationSample(
                timestamp: 1_713_000_000,
                latitude: 44.6488,
                longitude: -63.5752,
                horizontalAccuracyMeters: 12,
                speedKmh: 48,
                headingDegrees: 180
            )
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(locationService.startCount, 1)
        XCTAssertEqual(motionService.startCount, 1)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testSensorCoordinatorMatchesRecentPotholeCandidateForManualSeverity() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )

        let location = LocationSample(
            timestamp: 1_713_000_000,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 8,
            speedKmh: 35,
            headingDegrees: 180
        )
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))
        locationService.send(location)
        try? await Task.sleep(for: .milliseconds(10))
        motionService.sendVerticalAcceleration(-0.8, timestamp: 1_713_000_000.1)
        motionService.sendVerticalAcceleration(2.6, timestamp: 1_713_000_000.2)

        var matched: PotholeCandidate?
        for _ in 0..<20 {
            matched = coordinator.strongestRecentPotholeCandidate(
                near: location,
                now: Date(timeIntervalSince1970: 1_713_000_005)
            )
            if matched != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(matched?.magnitudeG, 2.6)
        XCTAssertEqual(coordinator.diagnostics.lastPotholeCandidateAt, Date(timeIntervalSince1970: location.timestamp))

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testSensorCoordinatorSchedulesUploadDrainAfterDrivingStops() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        var scheduledDates: [Date] = []

        let uploadDrainScheduled = expectation(description: "upload drain scheduled")
        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            stopCollectionGracePeriod: .milliseconds(20),
            nowProvider: { now },
            scheduleUploadDrain: {
                scheduledDates.append($0)
                uploadDrainScheduled.fulfill()
            }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))

        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)

        drivingDetector.send(false)
        await fulfillment(of: [uploadDrainScheduled], timeout: 1.0)

        XCTAssertFalse(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(locationService.stopCount, 1)
        XCTAssertEqual(motionService.stopCount, 1)
        XCTAssertEqual(scheduledDates, [now.addingTimeInterval(15 * 60)])

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    // Regression test for the P2 fix: stopCollection (triggered e.g. by the
    // driving-false grace period elapsing while parked) used to leave the
    // last-written checkpoint on disk with wasCollecting: true, because only
    // stopMonitoring cleared it. If the app were killed and relaunched within
    // the checkpoint's restore window, the stale checkpoint would resume
    // full-power GPS + 50Hz motion collection while stationary, needlessly
    // draining battery. This asserts the checkpoint file is gone as soon as
    // collection legitimately stops, without waiting for stopMonitoring.
    @MainActor
    func testSensorCoordinatorClearsCheckpointWhenCollectionStopsWithoutFullMonitoringStop() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        // A privacy zone force-persists a checkpoint on every sample inside
        // it (see handleLocationSample), which gives a deterministic way to
        // seed a checkpoint on disk without waiting on reading-window timing.
        let zoneLatitude = 44.6488
        let zoneLongitude = -63.5752
        context.insert(
            PrivacyZoneRecord(
                label: "Home",
                latitude: zoneLatitude,
                longitude: zoneLongitude,
                radiusM: 300,
                createdAt: Date(timeIntervalSince1970: 1_713_000_000)
            )
        )
        try context.save()

        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let uploadDrainScheduled = expectation(description: "upload drain scheduled")
        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            stopCollectionGracePeriod: .milliseconds(20),
            nowProvider: { now },
            scheduleUploadDrain: { _ in uploadDrainScheduled.fulfill() }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))

        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)

        // Sample sits inside the privacy zone, forcing a checkpoint write —
        // simulating the periodic in-drive checkpoint that would otherwise
        // exist by the time driving stops.
        locationService.send(
            LocationSample(
                timestamp: now.timeIntervalSince1970,
                latitude: zoneLatitude,
                longitude: zoneLongitude,
                horizontalAccuracyMeters: 8,
                speedKmh: 15,
                headingDegrees: 180
            )
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(try checkpointStore.load(maxAge: 30 * 60, now: now))

        // Driving stops; after the grace period, stopCollection runs without
        // stopMonitoring ever being called.
        drivingDetector.send(false)
        await fulfillment(of: [uploadDrainScheduled], timeout: 1.0)

        XCTAssertFalse(coordinator.monitoringState.isCollecting)
        XCTAssertTrue(coordinator.monitoringState.isMonitoring, "monitoring itself should still be active")
        XCTAssertNil(
            try checkpointStore.load(maxAge: 30 * 60, now: now),
            "stopCollection must clear the checkpoint so a killed-while-parked app does not resume full-power collection on relaunch"
        )

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    // Regression test for the P2 fix: handleLocationSample set latestLocation
    // to the raw sample before the privacy-zone check ran, and the
    // force-persisted checkpoint on a privacy-zone drop could therefore
    // contain an in-zone (home/work) coordinate written to plain JSON on
    // disk. Privacy zones are processed on-device and the server must never
    // see readings near a protected zone — the on-disk checkpoint is a leak
    // vector the review flagged. This asserts the persisted checkpoint's
    // latestLocation is nil after a privacy-zone-dropped sample.
    @MainActor
    func testSensorCoordinatorRedactsLocationInCheckpointAfterPrivacyZoneDrop() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let zoneLatitude = 44.6488
        let zoneLongitude = -63.5752
        context.insert(
            PrivacyZoneRecord(
                label: "Home",
                latitude: zoneLatitude,
                longitude: zoneLongitude,
                radiusM: 300,
                createdAt: Date(timeIntervalSince1970: 1_713_000_000)
            )
        )
        try context.save()

        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            nowProvider: { now },
            scheduleUploadDrain: { _ in }
        )

        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)

        // Sample sits inside the privacy zone radius, so it must be dropped
        // and the checkpoint force-persisted with a redacted location.
        locationService.send(
            LocationSample(
                timestamp: now.timeIntervalSince1970,
                latitude: zoneLatitude,
                longitude: zoneLongitude,
                horizontalAccuracyMeters: 8,
                speedKmh: 15,
                headingDegrees: 180
            )
        )
        try? await Task.sleep(for: .milliseconds(20))

        let checkpoint = try checkpointStore.load(maxAge: 30 * 60, now: now)
        XCTAssertNotNil(checkpoint, "a checkpoint should still be written after the privacy-zone drop")
        XCTAssertNil(
            checkpoint?.latestLocation,
            "the in-zone coordinate must never be persisted to the on-disk checkpoint"
        )

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    // Regression test for P0-2 (docs/reviews/2026-06-11-ios-prelaunch-review.md):
    // pausing monitoring used to cancel the consumer tasks of init-created
    // single-use AsyncStreams, so a resume never received samples again.
    @MainActor
    func testSensorCoordinatorResumesSampleDeliveryAfterMonitoringRestart() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )

        // First session: samples flow and collection starts.
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)

        // Pause (Settings toggle path) tears the consumer tasks down.
        coordinator.stopMonitoring()
        XCTAssertFalse(coordinator.monitoringState.isMonitoring)
        XCTAssertFalse(coordinator.monitoringState.isCollecting)

        // Resume: all three streams must deliver again.
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))

        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(locationService.startCount, 2)
        XCTAssertEqual(motionService.startCount, 2)

        let location = LocationSample(
            timestamp: 1_713_000_000,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 8,
            speedKmh: 35,
            headingDegrees: 180
        )
        locationService.send(location)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            coordinator.diagnostics.lastLocationSampleAt,
            Date(timeIntervalSince1970: location.timestamp)
        )

        motionService.sendVerticalAcceleration(-0.8, timestamp: 1_713_000_000.1)
        motionService.sendVerticalAcceleration(2.6, timestamp: 1_713_000_000.2)

        var matched: PotholeCandidate?
        for _ in 0..<20 {
            matched = coordinator.strongestRecentPotholeCandidate(
                near: location,
                now: Date(timeIntervalSince1970: 1_713_000_005)
            )
            if matched != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(matched?.magnitudeG, 2.6)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testUploaderDrainOnceUploadsQueuedPotholeAction() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        let actionID = UUID()
        context.insert(
            PotholeActionRecord(
                id: actionID,
                actionType: .manualReport,
                latitude: 44.6488,
                longitude: -63.5752,
                accuracyM: 4,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010),
                createdAt: Date(timeIntervalSince1970: 1_713_000_011),
                uploadState: .pendingUpload,
                sensorBackedMagnitudeG: 2.6,
                sensorBackedAt: Date(timeIntervalSince1970: 1_713_000_008)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/pothole-actions")
            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                PotholeActionUploadRequest.self,
                from: try requestBody(for: request)
            )
            XCTAssertEqual(payload.actionID, actionID)
            XCTAssertEqual(payload.actionType, PotholeActionType.manualReport.rawValue)
            XCTAssertEqual(payload.sensorBackedMagnitudeG, 2.6)
            XCTAssertEqual(payload.sensorBackedAt, Date(timeIntervalSince1970: 1_713_000_008))
            XCTAssertFalse(payload.deviceToken.isEmpty)

            let encoder = UploadCodec.makeEncoder()
            let data = try encoder.encode(
                PotholeActionUploadResponse(
                    actionID: payload.actionID,
                    potholeReportID: UUID(),
                    status: "accepted"
                )
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["x-request-id": "req-pothole-1"]
                )!,
                data
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let now = Date(timeIntervalSince1970: 1_713_000_100)
        await uploader.drainOnce(now: now)

        let updatedContext = ModelContext(container)
        let remainingActions = try updatedContext.fetch(FetchDescriptor<PotholeActionRecord>())
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        // Successful uploads soft-delete (set uploadedAt) instead of removing
        // the row, so reconcileManualReportStats can recover the count if the
        // stat is ever lost.
        XCTAssertEqual(remainingActions.count, 1)
        XCTAssertNotNil(remainingActions.first?.uploadedAt)
        XCTAssertTrue(batches.isEmpty)
    }

    @MainActor
    func testUploaderDrainOnceUploadsQueuedPotholePhoto() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let fileURL = tempDirectory.appendingPathComponent("photo.jpg")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: fileURL)

        let reportID = UUID()
        context.insert(
            PotholeReportRecord(
                id: reportID,
                photoFilePath: fileURL.path,
                latitude: 44.6488,
                longitude: -63.5752,
                accuracyM: 5,
                capturedAt: Date(timeIntervalSince1970: 1_713_000_010),
                uploadState: .pendingMetadata,
                byteSize: 4,
                sha256Hex: String(repeating: "a", count: 64)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/functions/v1/pothole-photos" {
                let encoder = UploadCodec.makeEncoder()
                let data = try encoder.encode(
                    PotholePhotoUploadResponse(
                        reportID: reportID,
                        uploadURL: URL(string: "https://uploads.example.invalid/pothole.jpg")!,
                        uploadExpiresAt: Date(timeIntervalSince1970: 1_713_007_300),
                        expectedObjectPath: "pending/\(reportID.uuidString.lowercased()).jpg"
                    )
                )
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["x-request-id": "req-photo-1"]
                    )!,
                    data
                )
            }

            XCTAssertEqual(request.url?.host, "uploads.example.invalid")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-SHA256"))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                Data()
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        await uploader.drainOnce(now: Date(timeIntervalSince1970: 1_713_000_100))

        let updatedContext = ModelContext(container)
        let reports = try updatedContext.fetch(FetchDescriptor<PotholeReportRecord>())
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.uploadState, .pendingModeration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // Regression test for NEW-2 (docs/reviews/2026-06-11-backend-prelaunch-review.md):
    // while the server's photo flow is disabled pending its R2 bucket, the
    // gateway answers /pothole-photos with 503 photos_disabled + Retry-After.
    // The queued photo must stay retryable (never failedPermanent), honor the
    // server's pause, and keep its bytes on disk for the eventual upload.
    @MainActor
    func testUploaderDefersQueuedPhotoOnPhotosDisabledResponse() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try DeviceTokenStore.currentToken(
            in: context,
            now: Date(timeIntervalSince1970: 1_713_000_000),
            makeUUID: { "device-token" }
        )

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let fileURL = tempDirectory.appendingPathComponent("photo.jpg")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: fileURL)

        let reportID = UUID()
        context.insert(
            PotholeReportRecord(
                id: reportID,
                photoFilePath: fileURL.path,
                latitude: 44.6488,
                longitude: -63.5752,
                accuracyM: 5,
                capturedAt: Date(timeIntervalSince1970: 1_713_000_010),
                uploadState: .pendingMetadata,
                byteSize: 4,
                sha256Hex: String(repeating: "a", count: 64)
            )
        )
        try context.save()

        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/pothole-photos")
            let body = try JSONSerialization.data(withJSONObject: [
                "error": "photos_disabled",
                "message": "Photo uploads are temporarily disabled.",
                "request_id": "req-photo-disabled-1",
                "retry_after_s": 21_600,
            ])
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: [
                        "Retry-After": "21600",
                        "x-request-id": "req-photo-disabled-1",
                    ]
                )!,
                body
            )
        }

        let endpoints = Endpoints(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.test",
                supabaseAnonKey: "anon.test"
            )
        )
        let uploader = Uploader(
            container: container,
            potholeActionStore: PotholeActionStore(container: container),
            potholePhotoStore: PotholePhotoStore(container: container),
            queueStore: UploadQueueStore(container: container),
            client: APIClient(endpoints: endpoints, session: session),
            logger: .upload
        )

        let now = Date(timeIntervalSince1970: 1_713_000_100)
        await uploader.drainOnce(now: now)

        let updatedContext = ModelContext(container)
        let report = try XCTUnwrap(updatedContext.fetch(FetchDescriptor<PotholeReportRecord>()).first)
        XCTAssertEqual(report.uploadState, .pendingMetadata, "photos_disabled must not strand the photo permanently")
        XCTAssertEqual(report.lastHTTPStatusCode, 503)
        XCTAssertEqual(report.lastRequestID, "req-photo-disabled-1")
        XCTAssertEqual(report.nextAttemptAt, now.addingTimeInterval(21_600), "server Retry-After pause should be honored")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "photo bytes stay on-device for the eventual upload")
    }

    @MainActor
    func testPrivacyZoneStorePersistsAndClampsMinimumRadius() throws {
        let container = try makeInMemoryContainer()
        let store = PrivacyZoneStore(container: container)

        try store.save(
            label: "Home",
            latitude: 44.6488,
            longitude: -63.5752,
            radiusM: 180
        )

        let zones = try store.fetchAll()
        XCTAssertEqual(zones.count, 1)
        XCTAssertEqual(zones.first?.label, "Home")
        XCTAssertEqual(zones.first?.radiusM, 250)
        XCTAssertTrue(try store.hasConfiguredZones())
    }

    // Regression test for P0-4 (docs/reviews/2026-06-11-ios-prelaunch-review.md):
    // saved zones used to store the raw map-reticle coordinate — the user's
    // exact home — instead of the documented snapped + randomized-offset center.
    @MainActor
    func testPrivacyZoneStoreAppliesRandomizedOffsetOnSave() throws {
        let container = try makeInMemoryContainer()
        let store = PrivacyZoneStore(
            container: container,
            makeRandomAngleRadians: { .pi / 2 },
            makeRandomDistanceMeters: { 80 }
        )

        let rawLatitude = 44.64881
        let rawLongitude = -63.57523
        try store.save(
            label: "Home",
            latitude: rawLatitude,
            longitude: rawLongitude,
            radiusM: 300
        )

        let expected = PrivacyZoneFactory.makeZone(
            tappedLatitude: rawLatitude,
            tappedLongitude: rawLongitude,
            requestedRadiusMeters: 300,
            randomAngleRadians: .pi / 2,
            randomDistanceMeters: 80
        )
        let zone = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(zone.latitude, expected.latitude)
        XCTAssertEqual(zone.longitude, expected.longitude)
        XCTAssertEqual(zone.radiusM, expected.radiusMeters)

        let storedOffsetMeters = PrivacyZoneFactory.distanceMeters(
            fromLatitude: rawLatitude,
            fromLongitude: rawLongitude,
            toLatitude: zone.latitude,
            toLongitude: zone.longitude
        )
        XCTAssertGreaterThan(storedOffsetMeters, 0)
        XCTAssertLessThan(storedOffsetMeters, zone.radiusM, "home must stay inside its own zone")
    }

    @MainActor
    func testPrivacyZoneStoreMigratesLegacyRawZoneCentersExactlyOnce() throws {
        let container = try makeInMemoryContainer()
        let suiteName = "PrivacyZoneMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Simulate a zone saved before the offset fix: raw center on disk.
        let rawLatitude = 44.64881
        let rawLongitude = -63.57523
        let context = ModelContext(container)
        context.insert(
            PrivacyZoneRecord(
                label: "Home",
                latitude: rawLatitude,
                longitude: rawLongitude,
                radiusM: 300,
                createdAt: Date(timeIntervalSince1970: 1_713_000_000)
            )
        )
        try context.save()

        let store = PrivacyZoneStore(
            container: container,
            makeRandomAngleRadians: { .pi / 4 },
            makeRandomDistanceMeters: { 60 }
        )
        store.migrateLegacyRawZoneCentersIfNeeded(defaults: defaults, logger: .app)

        let expected = PrivacyZoneFactory.makeZone(
            tappedLatitude: rawLatitude,
            tappedLongitude: rawLongitude,
            requestedRadiusMeters: 300,
            randomAngleRadians: .pi / 4,
            randomDistanceMeters: 60
        )
        let migrated = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(migrated.latitude, expected.latitude)
        XCTAssertEqual(migrated.longitude, expected.longitude)
        XCTAssertTrue(defaults.bool(forKey: PrivacyZoneStore.legacyCenterMigrationKey))

        // Re-running (e.g. next launch) must not offset the center again — a
        // double offset could push the zone off the user's home entirely.
        let secondStore = PrivacyZoneStore(
            container: container,
            makeRandomAngleRadians: { .pi },
            makeRandomDistanceMeters: { 100 }
        )
        secondStore.migrateLegacyRawZoneCentersIfNeeded(defaults: defaults, logger: .app)

        let unchanged = try XCTUnwrap(secondStore.fetchAll().first)
        XCTAssertEqual(unchanged.latitude, expected.latitude)
        XCTAssertEqual(unchanged.longitude, expected.longitude)
    }

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainerProvider.makeInMemory()
    }

    @MainActor
    private func makeIsolatedCheckpointStore() throws -> SensorCheckpointStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoadSenseNSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return SensorCheckpointStore(
            fileURL: directory.appendingPathComponent("SensorCheckpoint.json", isDirectory: false)
        )
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum MockRequestBodyError: Error {
    case missingBody
}

private final class LockedTickClock: @unchecked Sendable {
    private let base: Date
    private let lock = NSLock()
    private var tick = 0

    init(base: Date) {
        self.base = base
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        defer { tick += 1 }
        return base.addingTimeInterval(Double(tick))
    }
}

private func requestBody(for request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        XCTFail("Expected upload request body")
        throw MockRequestBodyError.missingBody
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4_096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        if readCount < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeRawData)
        }
        if readCount == 0 {
            break
        }
        data.append(buffer, count: readCount)
    }

    if data.isEmpty {
        XCTFail("Expected upload request body")
        throw MockRequestBodyError.missingBody
    }

    return data
}

@MainActor
private final class StreamDrivingDetector: DrivingDetecting {
    private var continuation: AsyncStream<Bool>.Continuation?

    func makeEventStream() -> AsyncStream<Bool> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        self.continuation = continuation
        return stream
    }

    func start() {}
    func stop() {}

    func send(_ isDriving: Bool) {
        continuation?.yield(isDriving)
    }
}

@MainActor
private final class CountingLocationService: LocationServicing {
    private var continuation: AsyncStream<LocationSample>.Continuation?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var passiveStartCount = 0
    private(set) var passiveStopCount = 0
    private var bufferedSamples: [LocationSample] = []

    var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    var latestSample: LocationSample? { bufferedSamples.last }
    var recentSamples: [LocationSample] { bufferedSamples }

    func makeSampleStream() -> AsyncStream<LocationSample> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: LocationSample.self)
        self.continuation = continuation
        return stream
    }

    func startPassiveMonitoring() {
        passiveStartCount += 1
    }

    func stopPassiveMonitoring() {
        passiveStopCount += 1
    }

    func start() throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func requestAlwaysUpgrade() {}

    func send(_ sample: LocationSample) {
        bufferedSamples.append(sample)
        continuation?.yield(sample)
    }
}

@MainActor
private final class CountingMotionService: MotionServicing {
    private var continuation: AsyncStream<MotionSample>.Continuation?

    private(set) var startCount = 0
    private(set) var stopCount = 0

    func makeSampleStream() -> AsyncStream<MotionSample> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: MotionSample.self)
        self.continuation = continuation
        return stream
    }

    func start(hz: Double) throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func sendVerticalAcceleration(_ value: Double, timestamp: TimeInterval) {
        continuation?.yield(
            MotionSample(
                timestamp: timestamp,
                userAcceleration: MotionVector3(x: 0, y: 0, z: value),
                gravity: MotionVector3(x: 0, y: 0, z: 1)
            )
        )
    }
}

@MainActor
private struct StubThermalMonitor: ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState { .nominal }
}

@MainActor
private final class StubNetworkPath: NetworkPathProviding {
    var currentSnapshot: NetworkPathSnapshot

    init(snapshot: NetworkPathSnapshot) {
        self.currentSnapshot = snapshot
    }
}

@MainActor
private final class RecordingDrainCoordinator: UploadDrainCoordinating {
    private(set) var requestedReasons: [UploadDrainReason] = []

    func requestDrain(reason: UploadDrainReason) async -> Bool {
        requestedReasons.append(reason)
        return true
    }

    func cancelActiveDrain() {}
}

// MARK: - Privacy zones, thermal, retention, background tasks

@MainActor
private final class ControllableThermalMonitor: ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState
    private var continuation: AsyncStream<ProcessInfo.ThermalState>.Continuation?

    init(initialState: ProcessInfo.ThermalState = .nominal) {
        currentState = initialState
    }

    func makeStateStream() -> AsyncStream<ProcessInfo.ThermalState> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessInfo.ThermalState.self)
        self.continuation = continuation
        return stream
    }

    func send(_ state: ProcessInfo.ThermalState) {
        currentState = state
        continuation?.yield(state)
    }
}

extension NetworkAndUploaderTests {
    private static let zoneLatitude = 44.6488
    private static let zoneLongitude = -63.5752

    @MainActor
    private func seedHomeZone(in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(
            PrivacyZoneRecord(
                label: "Home",
                latitude: Self.zoneLatitude,
                longitude: Self.zoneLongitude,
                radiusM: 300,
                createdAt: Date(timeIntervalSince1970: 1_713_000_000)
            )
        )
        try context.save()
    }

    private func sample(latitude: Double, longitude: Double, at timestamp: TimeInterval) -> LocationSample {
        LocationSample(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: 8,
            speedKmh: 40,
            headingDegrees: 90
        )
    }

    @MainActor
    func testInZoneFixNeverStartsADriveSessionOrStoresItsCoordinate() async throws {
        let container = try makeInMemoryContainer()
        try seedHomeZone(in: container)
        let readingStore = ReadingStore(container: container)
        let locationService = CountingLocationService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: CountingMotionService(),
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: readingStore,
            logger: .app,
            checkpointStore: checkpointStore,
            nowProvider: { now },
            scheduleUploadDrain: { _ in }
        )
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))

        // Drive starts at home: the first fix is inside the zone.
        locationService.send(sample(latitude: Self.zoneLatitude, longitude: Self.zoneLongitude, at: now.timeIntervalSince1970))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(try readingStore.activeDriveSessionID(), "an in-zone fix must not open a drive session")
        let zoneRows = try ModelContext(container).fetch(
            FetchDescriptor<ReadingRecord>(predicate: #Predicate { $0.droppedByPrivacyZone == true })
        )
        XCTAssertEqual(zoneRows.count, 1)
        XCTAssertEqual(zoneRows.first?.latitude, 0)
        XCTAssertEqual(zoneRows.first?.longitude, 0)
        XCTAssertEqual(zoneRows.first?.speedKMH, 0)
        let checkpoint = try checkpointStore.load(maxAge: 30 * 60, now: now)
        XCTAssertNil(checkpoint?.latestLocation)
        XCTAssertEqual(checkpoint?.recentPotholes, [])

        // First fix outside the zone (~1.5 km east) opens the session there.
        let outsideLongitude = Self.zoneLongitude + 0.02
        locationService.send(sample(latitude: Self.zoneLatitude, longitude: outsideLongitude, at: now.timeIntervalSince1970 + 60))
        try? await Task.sleep(for: .milliseconds(20))

        let sessionID = try XCTUnwrap(try readingStore.activeDriveSessionID())
        let session = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<DriveSessionRecord>()).first { $0.id == sessionID }
        )
        XCTAssertEqual(session.startLatitude, Self.zoneLatitude, accuracy: 1e-9)
        XCTAssertEqual(session.startLongitude, outsideLongitude, accuracy: 1e-9)
        let adopted = try ModelContext(container).fetch(
            FetchDescriptor<ReadingRecord>(predicate: #Predicate { $0.droppedByPrivacyZone == true })
        )
        XCTAssertEqual(adopted.first?.driveSessionID, sessionID, "the in-zone count is attached to the drive")

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testPotholeDetectionIsSkippedInsidePrivacyZone() async throws {
        let container = try makeInMemoryContainer()
        try seedHomeZone(in: container)
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))

        let inZone = sample(latitude: Self.zoneLatitude, longitude: Self.zoneLongitude, at: 1_713_000_000)
        locationService.send(inZone)
        try? await Task.sleep(for: .milliseconds(20))
        motionService.sendVerticalAcceleration(-0.8, timestamp: 1_713_000_000.1)
        motionService.sendVerticalAcceleration(2.6, timestamp: 1_713_000_000.2)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertNil(
            coordinator.strongestRecentPotholeCandidate(near: inZone, now: Date(timeIntervalSince1970: 1_713_000_005)),
            "no pothole candidate may be derived from in-zone travel"
        )
        XCTAssertNil(coordinator.diagnostics.lastPotholeCandidateAt)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testResetCurrentDriveSessionAfterDeleteStartsAFreshSession() async throws {
        let container = try makeInMemoryContainer()
        let readingStore = ReadingStore(container: container)
        let locationService = CountingLocationService()
        let drivingDetector = StreamDrivingDetector()
        let checkpointStore = try makeIsolatedCheckpointStore()
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: CountingMotionService(),
            drivingDetector: drivingDetector,
            thermalMonitor: StubThermalMonitor(),
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: readingStore,
            logger: .app,
            checkpointStore: checkpointStore,
            nowProvider: { now },
            scheduleUploadDrain: { _ in }
        )
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(10))
        locationService.send(sample(latitude: 44.70, longitude: -63.60, at: now.timeIntervalSince1970))
        try? await Task.sleep(for: .milliseconds(20))
        let firstSession = try XCTUnwrap(try readingStore.activeDriveSessionID())

        try readingStore.deleteAllContributionData()
        coordinator.resetCurrentDriveSession()

        XCTAssertNil(try checkpointStore.load(maxAge: 30 * 60, now: now))
        XCTAssertTrue(coordinator.monitoringState.isCollecting, "collection keeps running")

        locationService.send(sample(latitude: 44.71, longitude: -63.61, at: now.timeIntervalSince1970 + 30))
        try? await Task.sleep(for: .milliseconds(20))
        let secondSession = try XCTUnwrap(try readingStore.activeDriveSessionID())
        XCTAssertNotEqual(secondSession, firstSession)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testSeriousThermalStatePausesCollectionAndResumesOnRecovery() async throws {
        let container = try makeInMemoryContainer()
        let locationService = CountingLocationService()
        let motionService = CountingMotionService()
        let drivingDetector = StreamDrivingDetector()
        let thermal = ControllableThermalMonitor()
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermal,
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.monitoringState.isCollecting)

        thermal.send(.serious)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(coordinator.isThermallyPaused)
        XCTAssertFalse(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(motionService.stopCount, 1)

        thermal.send(.fair)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(coordinator.isThermallyPaused)
        XCTAssertTrue(coordinator.monitoringState.isCollecting, "collection resumes once the device cools")
        XCTAssertEqual(motionService.startCount, 2)

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testCriticalThermalStateAtLaunchDefersCollection() async throws {
        let container = try makeInMemoryContainer()
        let drivingDetector = StreamDrivingDetector()
        let motionService = CountingMotionService()
        let thermal = ControllableThermalMonitor(initialState: .critical)
        let checkpointStore = try makeIsolatedCheckpointStore()

        let coordinator = SensorCoordinator(
            locationService: CountingLocationService(),
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermal,
            privacyZoneStore: PrivacyZoneStore(container: container),
            readingStore: ReadingStore(container: container),
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        )
        coordinator.startMonitoring()
        try? await Task.sleep(for: .milliseconds(10))
        drivingDetector.send(true)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(coordinator.monitoringState.isCollecting)
        XCTAssertEqual(motionService.startCount, 0)

        thermal.send(.nominal)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(coordinator.monitoringState.isCollecting, "the deferred drive starts once the device cools")

        coordinator.stopMonitoring()
        try? checkpointStore.clear()
    }

    @MainActor
    func testFinalizeNeverUsesAPrivacyZoneRowAsTheDriveEndPoint() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let driveID = UUID()
        let start = Date(timeIntervalSince1970: 1_713_000_000)
        context.insert(
            DriveSessionRecord(id: driveID, startedAt: start, startLatitude: 44.60, startLongitude: -63.60)
        )
        context.insert(
            ReadingRecord(
                latitude: 44.62, longitude: -63.62, roughnessRMS: 0.05, speedKMH: 40, heading: 90,
                gpsAccuracyM: 5, isPothole: false, potholeMagnitude: nil,
                recordedAt: start.addingTimeInterval(60), driveSessionID: driveID
            )
        )
        // Legacy in-zone row that still carries a raw coordinate (the drive
        // ended at home). It is the latest row but must not become the end.
        context.insert(
            ReadingRecord(
                latitude: 44.6488, longitude: -63.5752, roughnessRMS: 0, speedKMH: 10, heading: 0,
                gpsAccuracyM: 5, isPothole: false, potholeMagnitude: nil,
                recordedAt: start.addingTimeInterval(120), driveSessionID: driveID,
                droppedByPrivacyZone: true
            )
        )
        try context.save()

        _ = try ReadingStore(container: container).finalizeDriveSession(id: driveID, now: start.addingTimeInterval(200))

        let session = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<DriveSessionRecord>()).first)
        XCTAssertEqual(session.endLatitude, 44.62)
        XCTAssertEqual(session.endLongitude, -63.62)
    }

    @MainActor
    func testScrubPrivacyFilteredCoordinatesZeroesLegacyRows() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(
            ReadingRecord(
                latitude: 44.6488, longitude: -63.5752, roughnessRMS: 0, speedKMH: 12, heading: 45,
                gpsAccuracyM: 6, isPothole: false, potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_000), droppedByPrivacyZone: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.70, longitude: -63.60, roughnessRMS: 0.05, speedKMH: 40, heading: 90,
                gpsAccuracyM: 5, isPothole: false, potholeMagnitude: nil,
                recordedAt: Date(timeIntervalSince1970: 1_713_000_010)
            )
        )
        try context.save()

        let store = ReadingStore(container: container)
        XCTAssertEqual(try store.scrubPrivacyFilteredCoordinates(), 1)
        XCTAssertEqual(try store.scrubPrivacyFilteredCoordinates(), 0, "already-scrubbed rows are left alone")

        let rows = try ModelContext(container).fetch(FetchDescriptor<ReadingRecord>())
        let zoneRow = try XCTUnwrap(rows.first { $0.droppedByPrivacyZone })
        XCTAssertEqual(zoneRow.latitude, 0)
        XCTAssertEqual(zoneRow.longitude, 0)
        XCTAssertEqual(zoneRow.heading, LocationSample.unknownHeading)
        let normalRow = try XCTUnwrap(rows.first { !$0.droppedByPrivacyZone })
        XCTAssertEqual(normalRow.latitude, 44.70)
        XCTAssertEqual(try store.privacyFilteredReadingCount(), 1, "the count survives the scrub")
    }

    @MainActor
    func testPruneExpiredLocalDataKeepsPendingWorkAndRecentHistory() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)

        func reading(_ recordedAt: Date, uploadedAt: Date? = nil, zone: Bool = false, session: UUID? = nil) -> ReadingRecord {
            ReadingRecord(
                latitude: 44.7, longitude: -63.6, roughnessRMS: 0.05, speedKMH: 40, heading: 90,
                gpsAccuracyM: 5, isPothole: false, potholeMagnitude: nil,
                recordedAt: recordedAt, driveSessionID: session, uploadedAt: uploadedAt,
                droppedByPrivacyZone: zone
            )
        }

        let emptyOldDrive = UUID()
        let oldDriveWithPending = UUID()
        context.insert(DriveSessionRecord(id: emptyOldDrive, startedAt: old, endedAt: old, startLatitude: 0, startLongitude: 0, isSealed: true))
        context.insert(DriveSessionRecord(id: oldDriveWithPending, startedAt: old, endedAt: old, startLatitude: 0, startLongitude: 0, isSealed: true))
        context.insert(reading(old, uploadedAt: old, session: emptyOldDrive))
        context.insert(reading(old, session: oldDriveWithPending))
        context.insert(reading(old, zone: true))
        context.insert(reading(recent, uploadedAt: recent))
        context.insert(UploadBatch(createdAt: old, lastAttemptAt: old, status: .succeeded, readingCount: 1))
        context.insert(UploadBatch(createdAt: old, lastAttemptAt: old, status: .pending, readingCount: 1))
        try context.save()

        let summary = try ReadingStore(container: container).pruneExpiredLocalData(now: now)

        XCTAssertEqual(summary.prunedReadingCount, 2, "old uploaded + old privacy-zone rows")
        XCTAssertEqual(summary.prunedBatchCount, 1, "only the terminal batch")
        XCTAssertEqual(summary.prunedDriveSessionCount, 1, "only the drive with nothing left")

        let after = ModelContext(container)
        let readings = try after.fetch(FetchDescriptor<ReadingRecord>())
        XCTAssertEqual(readings.count, 2)
        XCTAssertTrue(readings.contains { $0.uploadedAt == nil && $0.driveSessionID == oldDriveWithPending })
        XCTAssertEqual(try after.fetch(FetchDescriptor<UploadBatch>()).map(\.status), [.pending])
        XCTAssertEqual(try after.fetch(FetchDescriptor<DriveSessionRecord>()).map(\.id), [oldDriveWithPending])
    }

    @MainActor
    func testNightlyCleanupCompletesAndReschedules() throws {
        let container = try makeInMemoryContainer()
        let suiteName = "NightlyCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let sweeper = LocalRetentionSweeper(readingStore: ReadingStore(container: container), defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        var completions: [Bool] = []
        var scheduled: [Date] = []
        NightlyCleanupRunner.run(
            sweeper: sweeper,
            isExpired: { false },
            now: now,
            scheduleNext: { scheduled.append($0) },
            setTaskCompleted: { completions.append($0) }
        )
        XCTAssertEqual(completions, [true])
        XCTAssertEqual(scheduled, [now.addingTimeInterval(24 * 60 * 60)])

        NightlyCleanupRunner.run(
            sweeper: sweeper,
            isExpired: { true },
            now: now,
            scheduleNext: { scheduled.append($0) },
            setTaskCompleted: { completions.append($0) }
        )
        XCTAssertEqual(completions, [true, false], "an expired task reports failure without running")
        XCTAssertEqual(scheduled.count, 2, "and still books the next night")
    }

    @MainActor
    func testCheckpointIsWrittenWithFileProtection() throws {
        let store = try makeIsolatedCheckpointStore()
        try store.save(
            SensorCheckpoint(
                savedAt: Date(),
                wasCollecting: true,
                latestLocation: nil,
                recentPotholes: [],
                readingBuilder: ReadingBuilder().snapshot(),
                potholeDetector: PotholeDetector().snapshot()
            )
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        // The simulator may not report a protection class; a device must.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
    }

    func testDeleteRecoveredStoresRemovesBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveredStoresTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let backup = PersistentStoreRecovery.recoveredStoresDirectory(for: storeURL)
            .appendingPathComponent("2026-01-01", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("old store".utf8).write(to: backup.appendingPathComponent("default.store"))

        try PersistentStoreRecovery.deleteRecoveredStores(for: storeURL)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PersistentStoreRecovery.recoveredStoresDirectory(for: storeURL).path
        ))
        XCTAssertNoThrow(try PersistentStoreRecovery.deleteRecoveredStores(for: storeURL), "deleting again is a no-op")
    }

    func testMapboxTelemetryOptOutWritesTheSDKDefault() throws {
        let suiteName = "MapboxOptOut.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(MapboxTelemetryOptOut.isOptedOut(defaults: defaults))
        MapboxTelemetryOptOut.apply(defaults: defaults)
        XCTAssertTrue(MapboxTelemetryOptOut.isOptedOut(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: "MGLMapboxMetricsEnabled") as? Bool, false)
    }

    @MainActor
    func testUploadPayloadSendsNullHeadingForUnknownCourse() throws {
        let payload = UploadReadingPayload(
            lat: 44.7, lng: -63.6, roughnessRms: 0.05, speedKmh: 40,
            heading: LocationSample.unknownHeading, gpsAccuracyM: 5, isPothole: false,
            potholeMagnitude: nil, recordedAt: Date(timeIntervalSince1970: 1_713_000_000)
        )
        let data = try UploadCodec.makeEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["heading"] is NSNull, "the server requires the key; unknown course is sent as null")
    }
}
