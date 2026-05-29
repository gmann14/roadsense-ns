import XCTest
@testable import RoadSense_NS

final class RoadQualityMapSurfaceModeTests: XCTestCase {
    func testTestsAlwaysUseDeterministicTestingSurface() throws {
        let config = makeConfig(enableLiveMapboxMap: true)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: true),
            .testingShell
        )
    }

    func testReleaseDefaultUsesNativeFallbackSurface() throws {
        let config = makeConfig(enableLiveMapboxMap: false)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .nativeMapKitFallback
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
