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
        let capturedAt = Date(timeIntervalSince1970: 1_713_000_000)
        let requestNow = Date(timeIntervalSince1970: 1_713_000_100)
        let report = PotholeReportRecord(
            id: reportID,
            segmentID: nil,
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
                        accepted: 1_000,
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
        let tickQueue = DispatchQueue(label: "NetworkAndUploaderTests.tick")
        var tick = 0
        try await uploader.drainUntilBlocked(nowProvider: {
            tickQueue.sync {
                defer { tick += 1 }
                return base.addingTimeInterval(Double(tick))
            }
        })

        let updatedContext = ModelContext(container)
        let readings = try updatedContext.fetch(FetchDescriptor<ReadingRecord>())
        let batches = try updatedContext.fetch(FetchDescriptor<UploadBatch>())

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(readings.filter { $0.uploadedAt != nil }.count, 1_000)
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
                uploadState: .pendingUpload
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

        XCTAssertTrue(remainingActions.isEmpty)
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-SHA256"), String(repeating: "a", count: 64))
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

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainerProvider.makeInMemory()
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
