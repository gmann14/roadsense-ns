import SwiftUI
import UIKit
import XCTest
@testable import RoadSense_NS

/// Renders each `MapScreenRedesignPreview.MockScenario` to a PNG under
/// `docs/reviews/assets/` using `ImageRenderer`. Gated on the `MOCKUP_RENDER=1`
/// environment variable so it doesn't run during normal test invocations.
///
/// Run with:
/// ```
/// MOCKUP_RENDER=1 xcodebuild test \
///   -project ios/RoadSenseNS.xcodeproj \
///   -scheme RoadSenseNS \
///   -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
///   -only-testing:RoadSenseNSTests/MockupRenderTests/testRenderMockups
/// ```
@MainActor
final class MockupRenderTests: XCTestCase {
    func testRenderMockups() throws {
        guard ProcessInfo.processInfo.environment["MOCKUP_RENDER"] == "1" else {
            throw XCTSkip("Set MOCKUP_RENDER=1 to render mockups.")
        }

        let outputURL = URL(
            fileURLWithPath: "/Users/grahammann/conductor/workspaces/roadsense-ns/lima/docs/reviews/assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        // Render each scenario at two sizes:
        // - Standard: iPhone 17 Pro logical (393×852) → 1179×2556 px @3×.
        // - App Store: iPhone 6.7" (430×932) → 1290×2796 px @3×, the required
        //   submission size in App Store Connect.
        let standardSize = CGSize(width: 393, height: 852)
        let appStoreSize = CGSize(width: 430, height: 932)

        for scenario in MapScreenRedesignPreview.MockScenario.allCases {
            try renderScenario(
                scenario,
                size: standardSize,
                outputDir: outputURL,
                filenamePrefix: "mockup"
            )
            try renderScenario(
                scenario,
                size: appStoreSize,
                outputDir: outputURL,
                filenamePrefix: "appstore"
            )
        }
    }

    private func renderScenario(
        _ scenario: MapScreenRedesignPreview.MockScenario,
        size: CGSize,
        outputDir: URL,
        filenamePrefix: String
    ) throws {
        let view = StaticPreview(scenario: scenario)
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3.0
        renderer.proposedSize = ProposedViewSize(size)

        guard let uiImage = renderer.uiImage else {
            XCTFail("Failed to render \(filenamePrefix) \(scenario.rawValue) at \(size)")
            return
        }

        guard let data = uiImage.pngData() else {
            XCTFail("Failed to encode PNG for \(filenamePrefix) \(scenario.rawValue)")
            return
        }

        let slug = slugify(scenario.rawValue)
        let fileURL = outputDir.appendingPathComponent("\(filenamePrefix)-\(slug).png")
        try data.write(to: fileURL)
        print("[MockupRender] Wrote \(fileURL.path) (\(data.count) bytes)")
    }

    /// Renders the production `BrandMark` to the App Icon asset slot.
    /// iOS now accepts a single 1024×1024 universal icon (Xcode 15+); the OS
    /// scales for every other slot. Rendered with no transparency, no rounded
    /// corners (iOS applies the squircle mask).
    ///
    /// Run with:
    /// ```
    /// MOCKUP_RENDER=1 xcodebuild test \
    ///   -only-testing:RoadSenseNSTests/MockupRenderTests/testRenderAppIcon
    /// ```
    func testRenderAppIcon() throws {
        guard ProcessInfo.processInfo.environment["MOCKUP_RENDER"] == "1" else {
            throw XCTSkip("Set MOCKUP_RENDER=1 to render the app icon.")
        }

        let iconURL = URL(
            fileURLWithPath: "/Users/grahammann/conductor/workspaces/roadsense-ns/lima/ios/RoadSenseNS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            isDirectory: false
        )

        // App Store requires 1024×1024 with no transparency.
        let iconSize: CGFloat = 1024
        let iconView = BrandMark(size: iconSize)
            .frame(width: iconSize, height: iconSize)
            .background(DesignTokens.Palette.deep) // no-transparency safety
            .compositingGroup()

        let renderer = ImageRenderer(content: iconView)
        renderer.scale = 1.0 // 1024px logical = 1024px raster
        renderer.proposedSize = ProposedViewSize(width: iconSize, height: iconSize)

        guard let uiImage = renderer.uiImage else {
            XCTFail("Failed to render app icon")
            return
        }

        // Re-encode the rendered image without transparency, into a new
        // bitmap context, to satisfy the App Store's no-alpha rule strictly.
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1.0
        let opaqueImage = UIGraphicsImageRenderer(
            size: CGSize(width: iconSize, height: iconSize),
            format: format
        ).image { ctx in
            UIColor(DesignTokens.Palette.deep).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
            uiImage.draw(in: CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
        }

        guard let data = opaqueImage.pngData() else {
            XCTFail("Failed to encode app icon PNG")
            return
        }

        try data.write(to: iconURL)
        print("[MockupRender] Wrote \(iconURL.path) (\(data.count) bytes)")
    }

    private func slugify(_ value: String) -> String {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-"))
        let lowered = value
            .lowercased()
            .replacingOccurrences(of: "·", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var result = String(scalars)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
