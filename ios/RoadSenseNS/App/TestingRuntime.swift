import CoreLocation
import Foundation
import SwiftData

private enum TestingScenario: String {
    case defaultState = "default"
    case readyShell = "ready-shell"
}

@MainActor
private struct TestingPermissionManager: PermissionManaging {
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
private struct TestingLocationService: LocationServicing {
    var samples: AsyncStream<LocationSample> { AsyncStream { _ in } }
    var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    var latestSample: LocationSample? { nil }
    var recentSamples: [LocationSample] { [] }
    func start() throws {}
    func stop() {}
    func requestAlwaysUpgrade() {}
}

@MainActor
private struct TestingMotionService: MotionServicing {
    var samples: AsyncStream<MotionSample> { AsyncStream { _ in } }
    func start(hz: Double) throws {}
    func stop() {}
}

@MainActor
private struct TestingDrivingDetector: DrivingDetecting {
    var events: AsyncStream<Bool> { AsyncStream { _ in } }
    func start() {}
    func stop() {}
}

@MainActor
extension AppContainer {
    static func bootstrapForTesting(config: AppConfig) -> AppContainer {
        let scenario = TestingScenario(
            rawValue: ProcessInfo.processInfo.environment["ROAD_SENSE_TEST_SCENARIO"] ?? TestingScenario.defaultState.rawValue
        ) ?? .defaultState
        let logger = RoadSenseLogger.app
        let modelContainer: ModelContainer
        do {
            modelContainer = try ModelContainerProvider.makeInMemory()
        } catch {
            fatalError("Unable to create in-memory model container: \(error.localizedDescription)")
        }

        let privacyZoneStore = PrivacyZoneStore(container: modelContainer)
        let potholeActionStore = PotholeActionStore(container: modelContainer)
        let readingStore = ReadingStore(container: modelContainer)
        let userStatsStore = UserStatsStore(container: modelContainer)
        let uploadQueueStore = UploadQueueStore(container: modelContainer)
        let apiClient = APIClient(endpoints: Endpoints(config: config))
        let locationService = TestingLocationService()
        let motionService = TestingMotionService()
        let drivingDetector = TestingDrivingDetector()
        let thermalMonitor = ThermalMonitor()
        let checkpointStore = SensorCheckpointStore()
        let uploader = Uploader(
            container: modelContainer,
            potholeActionStore: potholeActionStore,
            queueStore: uploadQueueStore,
            client: apiClient,
            logger: .upload
        )
        let uploadDrainCoordinator = UploadDrainCoordinator(
            uploader: uploader,
            logger: .upload
        )

        seedTestingScenario(
            scenario: scenario,
            container: modelContainer,
            privacyZoneStore: privacyZoneStore
        )

        return AppContainer(
            config: config,
            permissions: TestingPermissionManager(),
            modelContainer: modelContainer,
            privacyZoneStore: privacyZoneStore,
            potholeActionStore: potholeActionStore,
            readingStore: readingStore,
            userStatsStore: userStatsStore,
            uploadQueueStore: uploadQueueStore,
            apiClient: apiClient,
            uploader: uploader,
            uploadDrainCoordinator: uploadDrainCoordinator,
            sensorCoordinator: SensorCoordinator(
                locationService: locationService,
                motionService: motionService,
                drivingDetector: drivingDetector,
                thermalMonitor: thermalMonitor,
                privacyZoneStore: privacyZoneStore,
                readingStore: readingStore,
                logger: logger,
                checkpointStore: checkpointStore,
                scheduleUploadDrain: { _ in }
            ),
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermalMonitor,
            logger: logger
        )
    }

    private static func seedTestingScenario(
        scenario: TestingScenario,
        container: ModelContainer,
        privacyZoneStore: PrivacyZoneStore
    ) {
        guard scenario == .readyShell else { return }

        do {
            try privacyZoneStore.save(
                label: "Home",
                latitude: 44.6488,
                longitude: -63.5752,
                radiusM: 300
            )

            let context = ModelContext(container)
            let baseTime = Date(timeIntervalSince1970: 1_713_000_000)

            context.insert(
                ReadingRecord(
                    latitude: 44.6488,
                    longitude: -63.5752,
                    roughnessRMS: 1.05,
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
                    latitude: 44.6491,
                    longitude: -63.5750,
                    roughnessRMS: 1.18,
                    speedKMH: 51,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: true,
                    potholeMagnitude: 2.7,
                    recordedAt: baseTime.addingTimeInterval(12)
                )
            )
            context.insert(
                ReadingRecord(
                    latitude: 44.6494,
                    longitude: -63.5748,
                    roughnessRMS: 0.0,
                    speedKMH: 18,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: false,
                    potholeMagnitude: nil,
                    recordedAt: baseTime.addingTimeInterval(24),
                    droppedByPrivacyZone: true
                )
            )
            context.insert(
                UserStats(
                    totalKmRecorded: 2.4,
                    totalSegmentsContributed: 7,
                    lastDriveAt: baseTime.addingTimeInterval(12),
                    potholesReported: 1
                )
            )
            try context.save()
        } catch {
            fatalError("Unable to seed UI test scenario: \(error.localizedDescription)")
        }
    }
}
