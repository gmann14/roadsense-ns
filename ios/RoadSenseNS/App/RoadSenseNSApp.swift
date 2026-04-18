import SwiftUI

@main
struct RoadSenseNSApp: App {
    private let config = AppBootstrap.loadConfig()

    var body: some Scene {
        WindowGroup {
            ContentView(config: config)
        }
    }
}
