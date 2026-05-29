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
    }

    @Test
    func productionKeepsPotholePhotosEnabled() throws {
        let productionConfig = packageRoot()
            .appendingPathComponent("Config/RoadSenseNS.Production.xcconfig")
        let workflow = packageRoot()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/ios-testflight.yml")

        #expect(try String(contentsOf: productionConfig, encoding: .utf8)
            .contains("ENABLE_POTHOLE_PHOTOS = YES"))
        #expect(try String(contentsOf: workflow, encoding: .utf8)
            .contains("ENABLE_POTHOLE_PHOTOS: \"YES\""))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
