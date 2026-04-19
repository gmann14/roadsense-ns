import Foundation
import SwiftData

@MainActor
struct AppContainer {
    let config: AppConfig
    let permissions: PermissionManaging
    let modelContainer: ModelContainer
    let privacyZoneStore: PrivacyZoneStoring
    let readingStore: ReadingStore
    let userStatsStore: UserStatsStore
    let uploadQueueStore: UploadQueueStore
    let apiClient: APIClient
    let uploader: Uploader
    let sensorCoordinator: SensorCoordinator
    let locationService: LocationServicing
    let motionService: MotionServicing
    let drivingDetector: DrivingDetecting
    let thermalMonitor: ThermalMonitoring
    let logger: RoadSenseLogger

    static func bootstrap(config: AppConfig) -> AppContainer {
        let logger = RoadSenseLogger.app
        let modelContainer: ModelContainer
        do {
            modelContainer = try ModelContainerProvider.makeDefault()
        } catch {
            fatalError("Unable to create model container: \(error.localizedDescription)")
        }

        let privacyZoneStore = PrivacyZoneStore(container: modelContainer)
        let readingStore = ReadingStore(container: modelContainer)
        let userStatsStore = UserStatsStore(container: modelContainer)
        let uploadQueueStore = UploadQueueStore(container: modelContainer)
        let apiClient = APIClient(endpoints: Endpoints(config: config))
        let locationService = LocationService()
        let motionService = MotionService()
        let drivingDetector = DrivingDetector()
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
            permissions: SystemPermissionManager(),
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
