import Foundation
import Testing

struct ReleaseConfigFilesTests {
    @Test
    func releaseInputsKeepMapFollowPuckOff() throws {
        let iosRoot = packageRoot()
        let repoRoot = iosRoot.deletingLastPathComponent()
        let checkedFiles = [
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Local.xcconfig"),
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Staging.xcconfig"),
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Production.xcconfig"),
            repoRoot.appendingPathComponent(".github/workflows/ios-testflight.yml"),
        ]

        for file in checkedFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(contents.contains("ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH"))
            #expect(contents.contains("ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH = NO")
                || contents.contains("ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH: \"NO\""))
        }
    }

    @Test
    func releaseInputsKeepLiveMapboxMapOff() throws {
        let iosRoot = packageRoot()
        let repoRoot = iosRoot.deletingLastPathComponent()
        let checkedFiles = [
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Local.xcconfig"),
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Staging.xcconfig"),
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Production.xcconfig"),
            repoRoot.appendingPathComponent(".github/workflows/ios-testflight.yml"),
        ]

        for file in checkedFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(contents.contains("ENABLE_LIVE_MAPBOX_MAP"))
            #expect(contents.contains("ENABLE_LIVE_MAPBOX_MAP = NO")
                || contents.contains("ENABLE_LIVE_MAPBOX_MAP: \"NO\""))
        }
    }

    @Test
    func publicReleaseInputsEnableRoadQualityVectorOverlay() throws {
        let iosRoot = packageRoot()
        let repoRoot = iosRoot.deletingLastPathComponent()
        let checkedFiles = [
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Staging.xcconfig"),
            iosRoot.appendingPathComponent("Config/RoadSenseNS.Production.xcconfig"),
            repoRoot.appendingPathComponent(".github/workflows/ios-testflight.yml"),
        ]

        for file in checkedFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(contents.contains("ENABLE_ROAD_QUALITY_VECTOR_OVERLAY"))
            #expect(contents.contains("ENABLE_ROAD_QUALITY_VECTOR_OVERLAY = YES")
                || contents.contains("ENABLE_ROAD_QUALITY_VECTOR_OVERLAY: \"YES\""))
        }
    }

    @Test
    func localConfigKeepsRoadQualityVectorOverlayOffWithoutSecrets() throws {
        let localConfig = packageRoot()
            .appendingPathComponent("Config/RoadSenseNS.Local.xcconfig")
        let contents = try String(contentsOf: localConfig, encoding: .utf8)

        #expect(contents.contains("ENABLE_ROAD_QUALITY_VECTOR_OVERLAY = NO"))
    }

    @Test
    func appInfoPlistExposesRuntimeFlags() throws {
        let infoPlist = packageRoot()
            .appendingPathComponent("RoadSenseNS/Resources/Info.plist")
        let contents = try String(contentsOf: infoPlist, encoding: .utf8)

        #expect(contents.contains("<key>ENABLE_POTHOLE_PHOTOS</key>"))
        #expect(contents.contains("<string>$(ENABLE_POTHOLE_PHOTOS)</string>"))
        #expect(contents.contains("<key>ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH</key>"))
        #expect(contents.contains("<string>$(ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH)</string>"))
        #expect(contents.contains("<key>ENABLE_LIVE_MAPBOX_MAP</key>"))
        #expect(contents.contains("<string>$(ENABLE_LIVE_MAPBOX_MAP)</string>"))
        #expect(contents.contains("<key>ENABLE_ROAD_QUALITY_VECTOR_OVERLAY</key>"))
        #expect(contents.contains("<string>$(ENABLE_ROAD_QUALITY_VECTOR_OVERLAY)</string>"))
    }

    // Photo uploads are deferred until the backend photo flow exists: the
    // production gateway answers /pothole-photos with 503 photos_disabled
    // until the R2 bucket + ported handlers ship (backend pre-launch review
    // NEW-2, backlog B130). Shipping a build with photos enabled would queue
    // photos against a disabled endpoint. Flip these assertions back to YES
    // in the same change that enables the server-side flow.
    @Test
    func productionKeepsPotholePhotosDisabledPendingPhotoBackend() throws {
        let productionConfig = packageRoot()
            .appendingPathComponent("Config/RoadSenseNS.Production.xcconfig")
        let workflow = packageRoot()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/ios-testflight.yml")

        #expect(try String(contentsOf: productionConfig, encoding: .utf8)
            .contains("ENABLE_POTHOLE_PHOTOS = NO"))
        #expect(try String(contentsOf: workflow, encoding: .utf8)
            .contains("ENABLE_POTHOLE_PHOTOS: \"NO\""))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
