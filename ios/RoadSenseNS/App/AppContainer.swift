import Foundation
import SwiftData

@MainActor
struct AppContainer {
    let config: AppConfig
    let permissions: PermissionManaging
    let modelContainer: ModelContainer
    let privacyZoneStore: PrivacyZoneStoring
    let uploadQueueStore: UploadQueueStore
    let apiClient: APIClient
    let uploader: Uploader
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
        let uploadQueueStore = UploadQueueStore(container: modelContainer)
        let apiClient = APIClient(endpoints: Endpoints(config: config))
        AppContainer(
            config: config,
            permissions: SystemPermissionManager(),
            modelContainer: modelContainer,
            privacyZoneStore: privacyZoneStore,
            uploadQueueStore: uploadQueueStore,
            apiClient: apiClient,
            uploader: Uploader(
                container: modelContainer,
                queueStore: uploadQueueStore,
                client: apiClient,
                logger: .upload
            ),
            locationService: LocationService(),
            motionService: MotionService(),
            drivingDetector: DrivingDetector(),
            thermalMonitor: ThermalMonitor(),
            logger: logger
        )
    }
}
