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
                mapboxAccessToken: "pk.test"
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
            let decoder = UploadCodec.makeDecoder()
            let payload = try decoder.decode(
                UploadReadingsRequest.self,
                from: XCTUnwrap(request.httpBody)
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
                from: XCTUnwrap(request.httpBody)
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
                mapboxAccessToken: "pk.test"
            )
        )
        let uploader = Uploader(
            container: container,
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
                mapboxAccessToken: "pk.test"
            )
        )
        let uploader = Uploader(
            container: container,
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
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            ReadingRecord.self,
            UploadBatch.self,
            PrivacyZoneRecord.self,
            UserStats.self,
            DeviceTokenRecord.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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
