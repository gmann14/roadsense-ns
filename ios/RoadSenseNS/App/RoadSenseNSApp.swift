import MapboxMaps
import SwiftUI
import SwiftData

@main
struct RoadSenseNSApp: App {
    private let container: AppContainer

    init() {
        // Before any Mapbox API is touched, so the SDK never starts its own
        // telemetry for even one session.
        MapboxTelemetryOptOut.apply()
        let config = AppBootstrap.loadConfig()
        MapboxOptions.accessToken = config.mapboxAccessToken
        if AppBootstrap.isRunningTests {
            self.container = AppContainer.bootstrapForTesting(config: config)
        } else {
            SentryBootstrapper.bootstrap(config: config)
            let container = AppContainer.bootstrap(config: config)
            BackgroundTaskRegistrar.registerAll(
                logger: container.logger,
                uploadDrainCoordinator: container.uploadDrainCoordinator,
                retentionSweeper: LocalRetentionSweeper(
                    readingStore: container.readingStore,
                    logger: container.logger
                )
            )
            BackgroundTaskRegistrar.scheduleNightlyCleanup(logger: container.logger)
            self.container = container
        }
        ManualPotholeReporterRuntime.reporter = ManualPotholeReporter(container: self.container)
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
