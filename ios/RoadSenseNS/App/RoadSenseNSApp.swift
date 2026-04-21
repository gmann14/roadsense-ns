import MapboxMaps
import SwiftUI
import SwiftData

@main
struct RoadSenseNSApp: App {
    private let container: AppContainer

    init() {
        let config = AppBootstrap.loadConfig()
        MapboxOptions.accessToken = config.mapboxAccessToken
        if AppBootstrap.isRunningTests {
            self.container = AppContainer.bootstrapForTesting(config: config)
        } else {
            SentryBootstrapper.bootstrap(config: config)
            let container = AppContainer.bootstrap(config: config)
            BackgroundTaskRegistrar.registerAll(
                logger: container.logger,
                uploadDrainCoordinator: container.uploadDrainCoordinator
            )
            self.container = container
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder
    private var rootView: some View {
        let baseView = ContentView(container: container)
            .modelContainer(container.modelContainer)

        if let dynamicTypeSize = AppBootstrap.dynamicTypeSizeOverride() {
            baseView.dynamicTypeSize(dynamicTypeSize)
        } else {
            baseView
        }
    }
}
