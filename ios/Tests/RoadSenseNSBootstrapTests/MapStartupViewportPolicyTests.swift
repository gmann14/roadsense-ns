import Foundation
import Testing
@testable import RoadSenseNSBootstrap

struct MapStartupViewportPolicyTests {
    @Test
    func defaultsToFixedNovaScotiaCamera() throws {
        let config = try config(enableFollowPuck: nil)

        let policy = MapStartupViewportPolicy.initialViewport(for: config)

        #expect(policy.mode == .fixedNovaScotia)
        #expect(policy.centerLatitude == 45.0)
        #expect(policy.centerLongitude == -63.6)
        #expect(policy.zoom == 6.6)
    }

    @Test
    func onlyUsesFollowPuckWhenExplicitlyEnabled() throws {
        let disabled = MapStartupViewportPolicy.initialViewport(
            for: try config(enableFollowPuck: "NO")
        )
        let bogus = MapStartupViewportPolicy.initialViewport(
            for: try config(enableFollowPuck: "maybe")
        )
        let enabled = MapStartupViewportPolicy.initialViewport(
            for: try config(enableFollowPuck: "YES")
        )

        #expect(disabled.mode == .fixedNovaScotia)
        #expect(bogus.mode == .fixedNovaScotia)
        #expect(enabled.mode == .followPuck)
        #expect(enabled.zoom == 13.8)
    }

    private func config(enableFollowPuck: String?) throws -> AppConfig {
        var values = [
            "APP_ENV": "PRODUCTION",
            "API_BASE_URL": "https://roadsense.ca",
            "MAPBOX_ACCESS_TOKEN": "pk.test-token",
            "SUPABASE_ANON_KEY": "anon.test-key",
        ]
        values["ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH"] = enableFollowPuck
        return try AppConfig.fromDictionary(values)
    }
}
