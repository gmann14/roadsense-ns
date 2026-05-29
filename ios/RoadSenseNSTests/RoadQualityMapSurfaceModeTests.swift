import XCTest
@testable import RoadSense_NS

final class RoadQualityMapSurfaceModeTests: XCTestCase {
    func testTestsAlwaysUseDeterministicTestingSurface() throws {
        let config = makeConfig(enableLiveMapboxMap: true, enableRoadQualityVectorOverlay: true)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: true),
            .testingShell
        )
    }

    func testReleaseUsesUIKitVectorOverlayWhenEnabled() throws {
        let config = makeConfig(enableLiveMapboxMap: false, enableRoadQualityVectorOverlay: true)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .mapboxUIKitOverlay
        )
    }

    func testReleaseUsesNativeFallbackWhenAllMapboxSurfacesAreDisabled() throws {
        let config = makeConfig(enableLiveMapboxMap: false, enableRoadQualityVectorOverlay: false)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .nativeMapKitFallback
        )
    }

    func testLiveMapboxRequiresExplicitFlagOutsideTests() throws {
        let config = makeConfig(enableLiveMapboxMap: true, enableRoadQualityVectorOverlay: false)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .liveMapbox
        )
    }

    func testUIKitVectorOverlayTakesPrecedenceOverLegacySwiftUIMapboxPath() throws {
        let config = makeConfig(enableLiveMapboxMap: true, enableRoadQualityVectorOverlay: true)

        XCTAssertEqual(
            RoadQualityMapSurfaceMode.resolve(config: config, isRunningTests: false),
            .mapboxUIKitOverlay
        )
    }

    private func makeConfig(
        enableLiveMapboxMap: Bool,
        enableRoadQualityVectorOverlay: Bool
    ) -> AppConfig {
        AppConfig(
            environment: .production,
            apiBaseURL: URL(string: "https://api.nsroadsense.ca")!,
            mapboxAccessToken: "pk.test-token",
            supabaseAnonKey: "anon.test-key",
            enablePotholePhotos: true,
            enableMapFollowPuckOnLaunch: false,
            enableLiveMapboxMap: enableLiveMapboxMap,
            enableRoadQualityVectorOverlay: enableRoadQualityVectorOverlay
        )
    }
}
