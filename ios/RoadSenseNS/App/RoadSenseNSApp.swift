import SwiftUI
import SwiftData

@main
struct RoadSenseNSApp: App {
    private let container: AppContainer

    init() {
        let config = AppBootstrap.loadConfig()
        if AppBootstrap.isRunningTests {
            self.container = AppContainer.bootstrapForTesting(config: config)
        } else {
            SentryBootstrapper.bootstrap(config: config)
            let container = AppContainer.bootstrap(config: config)
            BackgroundTaskRegistrar.registerAll(logger: container.logger)
            self.container = container
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(container: container)
                .modelContainer(container.modelContainer)
        }
    }
}
