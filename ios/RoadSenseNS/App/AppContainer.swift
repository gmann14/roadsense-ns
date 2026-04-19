import Foundation

@MainActor
struct AppContainer {
    let config: AppConfig
    let permissions: PermissionManaging

    static func bootstrap(config: AppConfig) -> AppContainer {
        AppContainer(
            config: config,
            permissions: SystemPermissionManager()
        )
    }
}
