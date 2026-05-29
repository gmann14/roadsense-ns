import XCTest
@testable import RoadSense_NS

final class RoadQualityMapSurfaceModeTests: XCTestCase {
    func testTestsAlwaysUseSafeFallbackSurface() throws {
        let config = makeConfig(enableLiveMapboxMap: true)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: true),
            .safeFallback
        )
    }

    func testReleaseDefaultUsesSafeFallbackSurface() throws {
        let config = makeConfig(enableLiveMapboxMap: false)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .safeFallback
        )
    }

    func testLiveMapboxRequiresExplicitFlagOutsideTests() throws {
        let config = makeConfig(enableLiveMapboxMap: true)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .liveMapbox
        )
    }

    private func makeConfig(enableLiveMapboxMap: Bool) -> AppConfig {
        AppConfig(
            environment: .production,
            apiBaseURL: URL(string: "https://api.nsroadsense.ca")!,
            mapboxAccessToken: "pk.test-token",
            supabaseAnonKey: "anon.test-key",
            enablePotholePhotos: true,
            enableMapFollowPuckOnLaunch: false,
            enableLiveMapboxMap: enableLiveMapboxMap
        )
    }
}
