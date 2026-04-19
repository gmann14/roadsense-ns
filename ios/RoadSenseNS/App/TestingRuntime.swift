import CoreLocation
import Foundation
import SwiftData

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
private final class TestingPrivacyZoneStore: PrivacyZoneStoring {
    func fetchAll() throws -> [PrivacyZoneRecord] { [] }
    func hasConfiguredZones() throws -> Bool { false }
    func save(label: String, latitude: Double, longitude: Double, radiusM: Double) throws {}
    func delete(id: UUID) throws {}
}

@MainActor
private struct TestingLocationService: LocationServicing {
    var samples: AsyncStream<LocationSample> { AsyncStream { _ in } }
    var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
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
        let logger = RoadSenseLogger.app
        let modelContainer: ModelContainer
        do {
            modelContainer = try ModelContainerProvider.makeInMemory()
        } catch {
            fatalError("Unable to create in-memory model container: \(error.localizedDescription)")
        }

        let privacyZoneStore = TestingPrivacyZoneStore()
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
            queueStore: uploadQueueStore,
            client: apiClient,
            logger: .upload
        )

        return AppContainer(
            config: config,
            permissions: TestingPermissionManager(),
            modelContainer: modelContainer,
            privacyZoneStore: privacyZoneStore,
            readingStore: readingStore,
            userStatsStore: userStatsStore,
            uploadQueueStore: uploadQueueStore,
            apiClient: apiClient,
            uploader: uploader,
            sensorCoordinator: SensorCoordinator(
                locationService: locationService,
                motionService: motionService,
                drivingDetector: drivingDetector,
                thermalMonitor: thermalMonitor,
                privacyZoneStore: privacyZoneStore,
                readingStore: readingStore,
                uploader: uploader,
                logger: logger,
                checkpointStore: checkpointStore
            ),
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermalMonitor,
            logger: logger
        )
    }
}
