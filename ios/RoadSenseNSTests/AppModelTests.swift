import CoreLocation
import Foundation
import SwiftData
import UIKit
import XCTest
@testable import RoadSense_NS

@MainActor
final class AppModelTests: XCTestCase {
    func testReadyModelAutoStartsMonitoringOnInit() throws {
        let defaults = try makeDefaults()
        let model = AppModel(container: try makeContainer(), defaults: defaults)

        XCTAssertTrue(model.isPassiveMonitoringEnabled)
        XCTAssertFalse(model.isCollectionPausedByUser)
    }

    func testManualStopPreventsForegroundAutoRestart() async throws {
        let defaults = try makeDefaults()
        let model = AppModel(container: try makeContainer(), defaults: defaults)

        model.stopPassiveMonitoring()
        XCTAssertFalse(model.isPassiveMonitoringEnabled)
        XCTAssertTrue(model.isCollectionPausedByUser)

        await model.handleAppDidBecomeActive()

        XCTAssertFalse(model.isPassiveMonitoringEnabled)
        XCTAssertTrue(model.isCollectionPausedByUser)
    }

    func testForegroundActivationRequestsUploadDrain() async throws {
        let defaults = try makeDefaults()
        let uploadDrainer = CountingUploadDrainer()
        let model = AppModel(
            container: try makeContainer(uploadDrainer: uploadDrainer),
            defaults: defaults
        )

        await model.handleAppDidBecomeActive()

        XCTAssertEqual(uploadDrainer.callCount, 1)
    }

    func testLocalDriveOverlayShowsOnlyVisibleUnuploadedReadings() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let activeSessionID = UUID()

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 0.03,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: now,
                driveSessionID: activeSessionID
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6490,
                longitude: -63.5750,
                roughnessRMS: 0.11,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: now.addingTimeInterval(10),
                uploadReadyAt: now.addingTimeInterval(60)
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6492,
                longitude: -63.5748,
                roughnessRMS: 0.18,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: now.addingTimeInterval(20),
                uploadedAt: now.addingTimeInterval(120),
                uploadReadyAt: now.addingTimeInterval(60)
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6494,
                longitude: -63.5746,
                roughnessRMS: 0.07,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: now.addingTimeInterval(30),
                endpointTrimmedAt: now.addingTimeInterval(90)
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6496,
                longitude: -63.5744,
                roughnessRMS: 0.07,
                speedKMH: 45,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: now.addingTimeInterval(40),
                droppedByPrivacyZone: true
            )
        )
        try context.save()

        let overlayPoints = try ReadingStore(container: container).localDriveOverlayPoints()

        XCTAssertEqual(overlayPoints.map(\.roughnessCategory), ["smooth", "rough"])
        XCTAssertEqual(overlayPoints.map(\.latitude), [44.6488, 44.6490])
    }

    func testManualStartClearsPausedPreferenceAndRestartsMonitoring() throws {
        let defaults = try makeDefaults()
        let model = AppModel(container: try makeContainer(), defaults: defaults)

        model.stopPassiveMonitoring()
        XCTAssertFalse(model.isPassiveMonitoringEnabled)

        model.startPassiveMonitoring()

        XCTAssertTrue(model.isPassiveMonitoringEnabled)
        XCTAssertFalse(model.isCollectionPausedByUser)
    }

    func testMarkPotholeQueuesUndoableActionWhenLocationIsUsable() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.5,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 52,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            )
        )

        let model = AppModel(container: container, defaults: defaults)
        let result = model.markPothole(now: now)

        guard case let .queued(id) = result else {
            return XCTFail("Expected queued pothole action")
        }

        let context = ModelContext(container.modelContainer)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, id)
        XCTAssertEqual(records.first?.uploadState, .pendingUndo)
    }

    func testMarkPotholeRejectsStaleLocation() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let staleSample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 20,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 48,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: staleSample,
                recentSamples: [staleSample]
            )
        )

        let model = AppModel(container: container, defaults: defaults)
        XCTAssertEqual(model.markPothole(now: now), .unavailableLocation)
    }

    func testMarkPotholeRejectsPrivacyZoneOverlap() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.5,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 48,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            ),
            seedPrivacyZone: true
        )

        let model = AppModel(container: container, defaults: defaults)
        XCTAssertEqual(model.markPothole(now: now), .insidePrivacyZone)
    }

    func testUndoPotholeReportRemovesPendingAction() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.5,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 52,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            )
        )

        let model = AppModel(container: container, defaults: defaults)
        let result = model.markPothole(now: now)
        guard case let .queued(id) = result else {
            return XCTFail("Expected queued pothole action")
        }

        model.undoPotholeReport(
            id: id,
            now: now.addingTimeInterval(1)
        )

        let context = ModelContext(container.modelContainer)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertTrue(records.isEmpty)
    }

    func testRepeatedTapReusesPendingUndoAction() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.3,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 55,
            headingDegrees: 176
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            )
        )

        let model = AppModel(container: container, defaults: defaults)
        let first = model.markPothole(now: now)
        let second = model.markPothole(now: now.addingTimeInterval(2))

        guard case let .queued(firstID) = first,
              case let .queued(secondID) = second else {
            return XCTFail("Expected queued pothole action")
        }

        XCTAssertEqual(firstID, secondID)

        let context = ModelContext(container.modelContainer)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
    }

    func testQueuePotholeFollowUpCreatesPendingUploadAction() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.4,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 40,
            headingDegrees: 180
        )
        let potholeID = UUID()
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            )
        )

        let model = AppModel(container: container, defaults: defaults)
        let result = model.queuePotholeFollowUp(
            potholeReportID: potholeID,
            actionType: .confirmPresent,
            now: now
        )

        guard case let .queued(actionID) = result else {
            return XCTFail("Expected queued follow-up action")
        }

        let context = ModelContext(container.modelContainer)
        let records = try context.fetch(FetchDescriptor<PotholeActionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, actionID)
        XCTAssertEqual(records.first?.potholeReportID, potholeID)
        XCTAssertEqual(records.first?.actionType, .confirmPresent)
        XCTAssertEqual(records.first?.uploadState, .pendingUpload)
    }

    func testQueuePotholeFollowUpRejectsPrivacyZoneOverlap() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.4,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 40,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            ),
            seedPrivacyZone: true
        )

        let model = AppModel(container: container, defaults: defaults)
        let result = model.queuePotholeFollowUp(
            potholeReportID: UUID(),
            actionType: .confirmFixed,
            now: now
        )

        XCTAssertEqual(result, .insidePrivacyZone)
    }

    func testFollowUpPromptCandidateRequiresStoppedFreshLocation() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let movingSample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.4,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 42,
            headingDegrees: 180
        )
        let candidate = SegmentPothole(
            id: UUID(),
            status: "active",
            latitude: 44.64881,
            longitude: -63.57521,
            confirmationCount: 2,
            uniqueReporters: 2,
            lastConfirmedAt: now
        )
        let movingModel = AppModel(
            container: try makeContainer(
                locationService: TestLocationService(
                    latestSample: movingSample,
                    recentSamples: [movingSample]
                )
            ),
            defaults: defaults
        )

        XCTAssertNil(movingModel.followUpPromptCandidate(for: [candidate], now: now))

        let stoppedSample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.4,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 5,
            speedKmh: 0,
            headingDegrees: 180
        )
        let stoppedModel = AppModel(
            container: try makeContainer(
                locationService: TestLocationService(
                    latestSample: stoppedSample,
                    recentSamples: [stoppedSample]
                )
            ),
            defaults: defaults
        )

        XCTAssertEqual(stoppedModel.followUpPromptCandidate(for: [candidate], now: now)?.id, candidate.id)
    }

    func testSubmitPotholePhotoQueuesPendingMetadataReport() async throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.5,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 0,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            )
        )
        let model = AppModel(container: container, defaults: defaults)

        let result = await model.submitPotholePhoto(
            rawImageData: try makeJPEGData(),
            segmentID: UUID(),
            now: now
        )

        guard case let .queued(id) = result else {
            return XCTFail("Expected queued pothole photo")
        }

        let context = ModelContext(container.modelContainer)
        let reports = try context.fetch(FetchDescriptor<PotholeReportRecord>())
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.id, id)
        XCTAssertEqual(try XCTUnwrap(reports.first).latitude, sample.latitude, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(reports.first).longitude, sample.longitude, accuracy: 0.000001)
        XCTAssertEqual(reports.first?.uploadState, .pendingMetadata)
    }

    func testSubmitPotholePhotoRejectsPrivacyZoneOverlap() async throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.5,
            latitude: 44.6488,
            longitude: -63.5752,
            horizontalAccuracyMeters: 6,
            speedKmh: 0,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            ),
            seedPrivacyZone: true
        )
        let model = AppModel(container: container, defaults: defaults)
        let result = await model.submitPotholePhoto(rawImageData: try makeJPEGData(), now: now)

        XCTAssertEqual(result, .insidePrivacyZone)
    }

    func testSubmitPotholePhotoRejectsOutsideNovaScotiaCoverage() async throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let sample = LocationSample(
            timestamp: now.timeIntervalSince1970 - 0.5,
            latitude: 48.4284,
            longitude: -123.3656,
            horizontalAccuracyMeters: 6,
            speedKmh: 0,
            headingDegrees: 180
        )
        let container = try makeContainer(
            locationService: TestLocationService(
                latestSample: sample,
                recentSamples: [sample]
            )
        )
        let model = AppModel(container: container, defaults: defaults)
        let result = await model.submitPotholePhoto(rawImageData: try makeJPEGData(), now: now)

        XCTAssertEqual(result, .outsideCoverage)
    }

    private func makeDefaults(file: StaticString = #filePath, line: UInt = #line) throws -> UserDefaults {
        let suiteName = "AppModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated defaults suite", file: file, line: line)
            throw NSError(domain: "AppModelTests", code: 1)
        }

        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeContainer(
        locationService: TestLocationService? = nil,
        uploadDrainer: (any UploadDrainPerforming)? = nil,
        seedPrivacyZone: Bool = false
    ) throws -> AppContainer {
        let locationService = locationService ?? TestLocationService()
        let config = AppConfig(
            environment: .local,
            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
            mapboxAccessToken: "pk.test",
            supabaseAnonKey: "anon.test"
        )
        let modelContainer = try ModelContainerProvider.makeInMemory()
        let privacyZoneStore = PrivacyZoneStore(container: modelContainer)
        if seedPrivacyZone {
            try privacyZoneStore.save(
                label: "Home",
                latitude: 44.6488,
                longitude: -63.5752,
                radiusM: 300
            )
        }
        let potholeActionStore = PotholeActionStore(container: modelContainer)
        let potholePhotoStore = PotholePhotoStore(container: modelContainer)
        let readingStore = ReadingStore(container: modelContainer)
        let userStatsStore = UserStatsStore(container: modelContainer)
        let uploadQueueStore = UploadQueueStore(container: modelContainer)
        let apiClient = APIClient(endpoints: Endpoints(config: config))
        let motionService = TestMotionService()
        let drivingDetector = TestDrivingDetector()
        let thermalMonitor = TestThermalMonitor()
        let checkpointStore = SensorCheckpointStore()
        let uploader = uploadDrainer ?? IdleUploadDrainer()
        let uploadDrainCoordinator = UploadDrainCoordinator(
            uploader: uploader,
            logger: .upload
        )

        return AppContainer(
            config: config,
            permissions: TestPermissionManager(),
            modelContainer: modelContainer,
            privacyZoneStore: privacyZoneStore,
            potholeActionStore: potholeActionStore,
            potholePhotoStore: potholePhotoStore,
            readingStore: readingStore,
            userStatsStore: userStatsStore,
            uploadQueueStore: uploadQueueStore,
            apiClient: apiClient,
            uploader: Uploader(
                container: modelContainer,
                potholeActionStore: potholeActionStore,
                potholePhotoStore: potholePhotoStore,
                queueStore: uploadQueueStore,
                client: apiClient,
                logger: .upload
            ),
            uploadDrainCoordinator: uploadDrainCoordinator,
            sensorCoordinator: SensorCoordinator(
                locationService: locationService,
                motionService: motionService,
                drivingDetector: drivingDetector,
                thermalMonitor: thermalMonitor,
                privacyZoneStore: privacyZoneStore,
                readingStore: readingStore,
                logger: .app,
                checkpointStore: checkpointStore,
                scheduleUploadDrain: { _ in }
            ),
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermalMonitor,
            haptics: NoOpHaptics(),
            logger: .app
        )
    }
}

private func makeJPEGData() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    let image = renderer.image { context in
        UIColor.systemOrange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    guard let data = image.jpegData(compressionQuality: 0.9) else {
        throw NSError(domain: "AppModelTests", code: 2)
    }
    return data
}

@MainActor
private struct TestPermissionManager: PermissionManaging {
    func currentSnapshot(privacyZones: PrivacyZoneSetupState) -> PermissionSnapshot {
        PermissionSnapshot(
            location: .always,
            motion: .authorized,
            privacyZones: privacyZones
        )
    }

    func requestInitialPermissions(privacyZones: PrivacyZoneSetupState) async -> PermissionSnapshot {
        currentSnapshot(privacyZones: privacyZones)
    }
}

@MainActor
private struct TestLocationService: LocationServicing {
    let latestSampleOverride: LocationSample?
    let recentSamplesOverride: [LocationSample]

    init(
        latestSample: LocationSample? = nil,
        recentSamples: [LocationSample] = []
    ) {
        self.latestSampleOverride = latestSample
        self.recentSamplesOverride = recentSamples
    }

    var samples: AsyncStream<LocationSample> { AsyncStream { _ in } }
    var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    var latestSample: LocationSample? { latestSampleOverride }
    var recentSamples: [LocationSample] { recentSamplesOverride }
    func startPassiveMonitoring() {}
    func stopPassiveMonitoring() {}
    func start() throws {}
    func stop() {}
    func requestAlwaysUpgrade() {}
}

@MainActor
private struct TestMotionService: MotionServicing {
    var samples: AsyncStream<MotionSample> { AsyncStream { _ in } }
    func start(hz: Double) throws {}
    func stop() {}
}

@MainActor
private struct TestDrivingDetector: DrivingDetecting {
    var events: AsyncStream<Bool> { AsyncStream { _ in } }
    func start() {}
    func stop() {}
}

@MainActor
private struct TestThermalMonitor: ThermalMonitoring {
    var currentState: ProcessInfo.ThermalState { .nominal }
}

@MainActor
private final class IdleUploadDrainer: UploadDrainPerforming {
    func drainUntilBlocked(nowProvider: @escaping @Sendable () -> Date) async throws {}
}

@MainActor
private final class CountingUploadDrainer: UploadDrainPerforming {
    private(set) var callCount = 0

    func drainUntilBlocked(nowProvider: @escaping @Sendable () -> Date) async throws {
        callCount += 1
    }
}
