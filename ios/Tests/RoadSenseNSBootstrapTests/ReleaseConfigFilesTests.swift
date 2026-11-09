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

    // MARK: - App Review / privacy hygiene

    @Test
    func privacyManifestDeclaresNoTrackingAndRequiredReasonAPIs() throws {
        let manifest = try plistDictionary(at: "RoadSenseNS/PrivacyInfo.xcprivacy")

        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

        let apiTypes = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let userDefaults = apiTypes.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
        }
        #expect((userDefaults?["NSPrivacyAccessedAPITypeReasons"] as? [String]) == ["CA92.1"])
    }

    @Test
    func privacyManifestMatchesAppStorePrivacyLabels() throws {
        let manifest = try plistDictionary(at: "RoadSenseNS/PrivacyInfo.xcprivacy")
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])

        var linkedByType: [String: Bool] = [:]
        for entry in collected {
            let type = try #require(entry["NSPrivacyCollectedDataType"] as? String)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false, "\(type) must not be tracking")
            #expect(
                (entry["NSPrivacyCollectedDataTypePurposes"] as? [String]) == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                "\(type) purpose"
            )
            linkedByType[type] = entry["NSPrivacyCollectedDataTypeLinked"] as? Bool
        }

        // Keep in sync with the App Store Connect privacy labels.
        #expect(linkedByType == [
            "NSPrivacyCollectedDataTypePreciseLocation": true,
            "NSPrivacyCollectedDataTypeDeviceID": true,
            "NSPrivacyCollectedDataTypeEmailAddress": true,
            "NSPrivacyCollectedDataTypeCustomerSupport": true,
            "NSPrivacyCollectedDataTypeOtherDataTypes": true,
            "NSPrivacyCollectedDataTypeCrashData": false,
            "NSPrivacyCollectedDataTypePerformanceData": false,
            "NSPrivacyCollectedDataTypeOtherDiagnosticData": false,
        ])
        // Photos stay undeclared while App Store builds ship with photos off.
        #expect(linkedByType["NSPrivacyCollectedDataTypePhotosorVideos"] == nil)
    }

    @Test
    func shippingInfoPlistOmitsLocalNetworkingKeys() throws {
        let plist = try plistDictionary(at: "RoadSenseNS/Resources/Info.plist")

        #expect(plist["NSLocalNetworkUsageDescription"] == nil)
        #expect(plist["NSAppTransportSecurity"] == nil)
        #expect(plist["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    @Test
    func localInfoPlistOnlyAddsLocalNetworkingKeys() throws {
        let shipping = try plistDictionary(at: "RoadSenseNS/Resources/Info.plist")
        var local = try plistDictionary(at: "RoadSenseNS/Resources/Info-Local.plist")

        #expect(local["NSLocalNetworkUsageDescription"] is String)
        let ats = try #require(local["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)

        local.removeValue(forKey: "NSLocalNetworkUsageDescription")
        local.removeValue(forKey: "NSAppTransportSecurity")
        #expect(NSDictionary(dictionary: local).isEqual(to: shipping))
    }

    @Test
    func alwaysLocationPurposeSaysDrivesAreRecordedAutomatically() throws {
        let plist = try plistDictionary(at: "RoadSenseNS/Resources/Info.plist")
        let always = try #require(plist["NSLocationAlwaysAndWhenInUseUsageDescription"] as? String)

        #expect(always.localizedCaseInsensitiveContains("automatically"))
        #expect(always.localizedCaseInsensitiveContains("background"))
    }

    @Test
    func backgroundModesMatchSubmittedTasks() throws {
        let plist = try plistDictionary(at: "RoadSenseNS/Resources/Info.plist")
        let modes = try #require(plist["UIBackgroundModes"] as? [String])
        let identifiers = try #require(plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])

        // `processing` is required because nightly-cleanup is submitted as a
        // BGProcessingTaskRequest; `fetch` covers the upload-drain app refresh.
        #expect(Set(modes) == ["location", "processing", "fetch"])
        #expect(Set(identifiers) == ["ca.roadsense.ios.nightly-cleanup", "ca.roadsense.ios.upload-drain"])
    }

    @Test
    func committedXcconfigsCarryNoRealAPIKeys() throws {
        for name in ["Local", "Staging", "Production"] {
            let contents = try String(
                contentsOf: packageRoot().appendingPathComponent("Config/RoadSenseNS.\(name).xcconfig"),
                encoding: .utf8
            )
            let keyLine = contents
                .split(separator: "\n")
                .first { $0.hasPrefix("SUPABASE_ANON_KEY") }
            #expect(keyLine?.contains("anon.placeholder.") == true, "\(name) xcconfig must use a placeholder key")
        }
    }

    private func plistDictionary(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot().appendingPathComponent(relativePath))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
