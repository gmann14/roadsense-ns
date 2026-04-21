import Foundation
import SwiftData

@MainActor
struct AppContainer {
    let config: AppConfig
    let permissions: PermissionManaging
    let modelContainer: ModelContainer
    let privacyZoneStore: PrivacyZoneStoring
    let potholeActionStore: PotholeActionStore
    let readingStore: ReadingStore
    let userStatsStore: UserStatsStore
    let uploadQueueStore: UploadQueueStore
    let apiClient: APIClient
    let uploader: Uploader
    let uploadDrainCoordinator: UploadDrainCoordinator
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
        let potholeActionStore = PotholeActionStore(container: modelContainer)
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
            potholeActionStore: potholeActionStore,
            queueStore: uploadQueueStore,
            client: apiClient,
            logger: .upload
        )
        let uploadDrainCoordinator = UploadDrainCoordinator(
            uploader: uploader,
            logger: .upload
        )
        return AppContainer(
            config: config,
            permissions: SystemPermissionManager(),
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
                scheduleUploadDrain: { earliestBegin in
                    BackgroundTaskRegistrar.scheduleNextUploadDrain(
                        earliestBegin: earliestBegin,
                        logger: logger
                    )
                }
            ),
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermalMonitor,
            logger: logger
        )
    }
}
