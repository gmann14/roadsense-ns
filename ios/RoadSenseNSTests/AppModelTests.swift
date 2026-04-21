import CoreLocation
import Foundation
import SwiftData
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

        model.undoPotholeReport(id: id)

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
        let readingStore = ReadingStore(container: modelContainer)
        let userStatsStore = UserStatsStore(container: modelContainer)
        let uploadQueueStore = UploadQueueStore(container: modelContainer)
        let apiClient = APIClient(endpoints: Endpoints(config: config))
        let motionService = TestMotionService()
        let drivingDetector = TestDrivingDetector()
        let thermalMonitor = TestThermalMonitor()
        let checkpointStore = SensorCheckpointStore()
        let uploader = IdleUploadDrainer()
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
            readingStore: readingStore,
            userStatsStore: userStatsStore,
            uploadQueueStore: uploadQueueStore,
            apiClient: apiClient,
            uploader: Uploader(
                container: modelContainer,
                potholeActionStore: potholeActionStore,
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
            logger: .app
        )
    }
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
