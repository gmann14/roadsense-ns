public enum MapStartupViewportMode: Equatable, Sendable {
    case fixedNovaScotia
    case followPuck
}

public struct MapStartupViewportPolicy: Equatable, Sendable {
    public let mode: MapStartupViewportMode
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let zoom: Double

    public static let fixedNovaScotia = MapStartupViewportPolicy(
        mode: .fixedNovaScotia,
        centerLatitude: 45.0,
        centerLongitude: -63.6,
        zoom: 6.6
    )

    public static let followPuck = MapStartupViewportPolicy(
        mode: .followPuck,
        centerLatitude: 45.0,
        centerLongitude: -63.6,
        zoom: 13.8
    )

    public static func initialViewport(for config: AppConfig) -> MapStartupViewportPolicy {
        config.enableMapFollowPuckOnLaunch ? .followPuck : .fixedNovaScotia
    }
}
