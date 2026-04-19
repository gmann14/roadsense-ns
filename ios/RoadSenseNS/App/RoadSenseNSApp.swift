import SwiftUI

@main
struct RoadSenseNSApp: App {
    private let container = AppContainer.bootstrap(config: AppBootstrap.loadConfig())

    var body: some Scene {
        WindowGroup {
            ContentView(container: container)
        }
    }
}
